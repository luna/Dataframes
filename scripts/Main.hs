import Prelude
import Control.Monad
import Control.Monad.Extra
import Data.List
import Data.Maybe
import Data.Monoid
import Data.String.Utils (split)
import Distribution.Simple.Utils
import Distribution.System
import Distribution.Verbosity
import System.Directory
import System.Environment
import System.FilePath
import System.FilePath.Glob
import System.IO.Temp
import System.Process.Typed hiding (setEnv)

import qualified Package.Library as Library
import Utils

import qualified Platform                as Platform
import qualified Program                 as Program
import qualified Program.CMake           as CMake
import qualified Program.Curl            as Curl
import qualified Program.Git             as Git
import qualified Program.Ldd             as Ldd
import qualified Program.Patchelf        as Patchelf
import qualified Program.MsBuild         as MsBuild
import qualified Program.SevenZip        as SevenZip
import qualified Program.Tar             as Tar
import qualified Program.Otool           as Otool
import qualified Program.InstallNameTool as INT

import qualified Platform.MacOS   as MacOS
import qualified Platform.Linux   as Linux
import qualified Platform.Windows as Windows

depsArchiveUrl, packageBaseUrl :: String
depsArchiveUrl = "https://packages.luna-lang.org/dataframes/libs-dev-v140-v2.7z"
packageBaseUrl = "https://packages.luna-lang.org/dataframes/windows-package-base-v3.7z"

-- | Packaging script always builds Release-mode 64-bit executables
msBuildConfig :: MsBuild.BuildConfiguration
msBuildConfig = MsBuild.BuildConfiguration MsBuild.Release MsBuild.X64

-- | All paths below are functions over repository directory (or package root,
-- if applicable)
nativeLibsSrc      = (</> Library.nativeLibs </> "src")
solutionFile       = (</> "DataframeHelper.sln")     . nativeLibsSrc
dataframeVsProject = (</> "DataframeHelper.vcxproj") . nativeLibsSrc

-- | Function downloads archive from given URL and extracts it to the target
--  dir. The archive is placed in temp folder, so function doesn't leave any
--  trash behind.
downloadAndUnpack7z :: FilePath -> FilePath -> IO ()
downloadAndUnpack7z archiveUrl targetDirectory = do
    withSystemTempDirectory "" $ \tmpDir -> do
        let archiveLocalPath = tmpDir </> takeFileName archiveUrl
        Curl.download archiveUrl archiveLocalPath
        SevenZip.unpack archiveLocalPath targetDirectory

-- | Gets path to the local copy of the Dataframes repo
repoDir :: IO FilePath
repoDir = lookupEnv "BUILD_SOURCESDIRECTORY" >>= \case
    Just path -> pure path
    Nothing -> do
        exePath <- getExecutablePath 
        Git.repositoryRoot (takeDirectory exePath) >>= \case
            Just path -> pure path
            Nothing   -> do
                cwdDir <- getCurrentDirectory
                Git.repositoryRoot cwdDir >>= \case
                    Just path -> pure path
                    Nothing   -> error $ "cannot deduce repository root path, please define BUILD_SOURCESDIRECTORY"


-- | Path to directory with Python installation, should not contain other things
-- (that was passed as --prefix to Python's configure script)
pythonPrefix :: IO FilePath
pythonPrefix = getEnvRequired "PYTHON_PREFIX_PATH" -- TODO: should be able to deduce by looking for python in PATH

-- | Python version that we package, assumed to be already installed on
-- packaging system.
pythonVersion :: String
pythonVersion = "3.7"

-- Helper that does two things:
-- 1) use file extension to deduce compression method
-- 2) switch CWD so tar shall pack the folder at archive's root
--    (without maintaining directory's absolute path in archive)
packDirectory :: FilePath -> FilePath -> IO ()
packDirectory pathToPack outputArchive = do
    -- As we switch cwd, relative path to output might get affected.
    -- Let's store it as absolute path first.
    outputArchiveAbs <- makeAbsolute outputArchive
    withCurrentDirectory (takeDirectory pathToPack) $ do
        -- Input path must be relative though.
        pathToPackRel <- makeRelativeToCurrentDirectory pathToPack
        let tarPack =  Tar.pack [pathToPackRel] outputArchiveAbs
        case takeExtension outputArchive of
            ".7z"   -> SevenZip.pack [pathToPack] outputArchiveAbs
            ".gz"   -> tarPack Tar.GZIP
            ".bz2"  -> tarPack Tar.BZIP2
            ".xz"   -> tarPack Tar.XZ
            ".lzma" -> tarPack Tar.LZMA
            _       -> fail $ "packDirectory: cannot deduce compression algorithm from extension: " <> takeExtension outputArchive

dataframesPackageName :: String
dataframesPackageName = case buildOS of
    Windows -> "Dataframes-Win-x64.7z"
    Linux   -> "Dataframes-Linux-x64.tar.gz"
    OSX     -> "Dataframes-macOS-x64.tar.gz"
    _       -> error $ "dataframesPackageName: not implemented: " <> show buildOS

-- This function purpose is to transform environment from its initial state
-- to the state where build step can be executed - so all dependencies and
-- other global state (like environment variable) that build script is using
-- must be set.
prepareEnvironment :: FilePath -> IO ()
prepareEnvironment tempDir = do
    case buildOS of
        Windows -> do
            -- We need to extract the package with dev libraries and set the environment
            -- variable DATAFRAMES_DEPS_DIR so the MSBuild project recognizes it.
            --
            -- The package contains all dependencies except for Python (with numpy).
            -- Python needs to be provided by CI environment and pointed to by `PythonDir`
            -- environment variable.
            let depsDirLocal = tempDir </> "deps"
            downloadAndUnpack7z depsArchiveUrl depsDirLocal
            setEnv "DATAFRAMES_DEPS_DIR" depsDirLocal
        Linux ->
            -- On Linux all dependencies are assumed to be already installed. Such is the case
            -- with the Docker image used to run Dataframes CI, and should be similarly with
            -- developer machines.
            return ()
        OSX  -> return ()
        _     ->
            error $ "not implemented: prepareEnvironment for buildOS == " <> show buildOS


data DataframesBuildArtifacts = DataframesBuildArtifacts
    { dataframesBinaries :: [FilePath]
    , dataframesTests :: [FilePath]
    } deriving (Eq, Show)

-- | Function raises error if any of the reported build artifacts cannot be
--   found at the declared location.
verifyArtifacts :: DataframesBuildArtifacts -> IO ()
verifyArtifacts DataframesBuildArtifacts{..} = do
    let binaries = dataframesBinaries <> dataframesTests
    forM_ binaries $ \binary -> 
        unlessM (doesFileExist binary) 
            $ error $ "Failed to find built target binary: " <> binary

-- This function should be called only in a properly prepared build environment.
-- It builds the project and produces build artifacts.
buildProject :: FilePath -> FilePath -> IO DataframesBuildArtifacts
buildProject repoDir stagingDir = do
    putStrLn $ "Building project"

    -- In theory we could scan output directory for binaries… but the build
    -- script should know what it wants to build, so it feels better to just fix
    -- names here. Note that they need to be in sync with C++ project files
    -- (both CMake and MSBuild).
    let targetLibraries = Platform.libraryFilename 
                          <$> ["DataframeHelper", "DataframePlotter", "Learn"]
    let targetTests     = Platform.executableFilename 
                          <$> ["DataframeHelperTests"]
    let targets         = targetLibraries <> targetTests

    case buildOS of
        Windows -> do
            -- On Windows we don't care about Python, as it is discovered thanks
            -- to env's `PythonDir` and MS Build property sheets imported from
            -- deps package.
            -- All setup work is already done.
            MsBuild.build msBuildConfig $ solutionFile repoDir
        _ -> do
            -- CMake needs to get paths to:
            -- 1) python the library
            -- 2) numpy includes
            pythonPrefix <- pythonPrefix
            let buildDir = stagingDir </> "build"
            let srcDir = nativeLibsSrc repoDir
            let pythonLibDir = pythonPrefix </> "lib"
            let pythonLibName = "libpython" <> pythonVersion <> "m" <.> Platform.dllExtension
            let pythonLibPath = pythonLibDir </> pythonLibName
            let numpyIncludeDir = pythonLibDir </> "python" <> pythonVersion </> "site-packages/numpy/core/include"
            let cmakeVariables =  
                    [ CMake.SetVariable "PYTHON_LIBRARY"           pythonLibPath
                    , CMake.SetVariable "PYTHON_NUMPY_INCLUDE_DIR" numpyIncludeDir
                    ]
            let options = CMake.OptionBuildType CMake.ReleaseWithDebInfo 
                        : (CMake.OptionSetVariable <$> cmakeVariables)
            CMake.build buildDir srcDir options

    let builtBinariesDir = repoDir </> Library.nativeLibsBin
    let expectedArtifacts = DataframesBuildArtifacts
            { dataframesBinaries = (builtBinariesDir </>) <$> targetLibraries
            , dataframesTests    = (builtBinariesDir </>) <$> targetTests
            }
    verifyArtifacts expectedArtifacts
    pure expectedArtifacts

data DataframesPackageArtifacts = DataframesPackageArtifacts
    { dataframesPackageArchive :: FilePath
    , dataframesPackageDirectory :: FilePath
    } deriving (Eq, Show)

copyInPythonLibs :: FilePath -> FilePath -> IO ()
copyInPythonLibs pythonPrefix packageRoot = do
    let from = pythonPrefix </> "lib" </> "python" <> pythonVersion <> ""
    let to = packageRoot </> "python_libs"
    copyDirectoryRecursive normal from to
    pyCacheDirs <- glob $ to </> "**" </> "__pycache__"
    mapM removePathForcibly pyCacheDirs
    removePathForcibly $ to </> "config-" <> pythonVersion <> "m-x86_64-linux-gnu"
    removePathForcibly $ to </> "test"

-- | Windows-only, uses data provided by our MS Build property sheets to get
-- locations with dependenciess
additionalLocationsWithBinaries :: FilePath -> IO [FilePath]
additionalLocationsWithBinaries repoDir = do
    let projectPath = dataframeVsProject repoDir
    pathAdditions <- MsBuild.queryProperty msBuildConfig projectPath "PathAdditions"
    pure $ case pathAdditions of
            Just additions -> split ";" additions
            Nothing        -> []

packagePython :: FilePath -> FilePath -> IO ()
packagePython repoDir packageRoot = do
    case buildOS of
        Windows -> 
            -- We use pre-built package.
            downloadAndUnpack7z packageBaseUrl $ packageRoot </> Library.nativeLibsBin
        _ -> do
            -- Copy Python installation to the package and remove some parts that are heavy and not needed.
            pythonPrefix <- pythonPrefix
            copyInPythonLibs pythonPrefix packageRoot

packageNativeLibs :: FilePath -> DataframesBuildArtifacts -> FilePath -> IO ()
packageNativeLibs repoDir buildArtifacts nativeLibsDest = do
    let builtDlls = dataframesBinaries buildArtifacts
    when (null builtDlls) $ error "Build Library.action $ n have not build any binaries despite declaring success!"
    additionalDependencyDirs <- case buildOS of
            Windows -> additionalLocationsWithBinaries repoDir
            _       -> pure []
    Platform.packageBinaries nativeLibsDest builtDlls additionalDependencyDirs
    pure ()

package :: FilePath -> FilePath -> DataframesBuildArtifacts -> IO DataframesPackageArtifacts
package repoDir stagingDir buildArtifacts = do
    putStrLn $ "Packaging build artifacts..."
    let packageRoot = stagingDir </> "Dataframes"
    let packageNativeLibsHook nativeLibsDest = do
            packagePython repoDir packageRoot
            packageNativeLibs repoDir buildArtifacts nativeLibsDest

    Library.package repoDir packageRoot $ Library.Hooks
        { _installNativeLibs = Library.Hook $ packageNativeLibsHook }
    packDirectory packageRoot dataframesPackageName
    putStrLn $ "Packaging done, file saved to: " <> dataframesPackageName
    pure $ DataframesPackageArtifacts
        { dataframesPackageArchive = dataframesPackageName
        , dataframesPackageDirectory = packageRoot
        }

runTests :: FilePath -> DataframesBuildArtifacts -> DataframesPackageArtifacts -> IO ()
runTests repoDir buildArtifacts packageArtifacts = do
    -- The test executable must be placed in the package directory
    -- so all the dependencies are properly visible.
    -- The CWD must be repository though for test to properly find
    -- the data files.
    let packageDirBinaries = dataframesPackageDirectory packageArtifacts </> Library.nativeLibsBin
    tests <- mapM (copyToDir packageDirBinaries) (dataframesTests buildArtifacts)
    withCurrentDirectory repoDir $ do
        let configs = flip proc ["--report_level=detailed"] <$> tests
        mapM_ runProcess_ configs


main :: IO ()
main = do
    -- putStrLn $ "Starting Dataframes build"
    withSystemTempDirectory "" $ \stagingDir -> do
        -- let stagingDir = "C:\\Users\\mwu\\AppData\\Local\\Temp\\-777f232250ff9e9c"
        putStrLn $ "Preparing environment..."
        prepareEnvironment stagingDir
        putStrLn $ "Obtaining repository directory..."
        repoDir <- repoDir
        buildArtifacts <- buildProject repoDir stagingDir
        packageArtifacts <- package repoDir stagingDir buildArtifacts
        runTests repoDir buildArtifacts packageArtifacts
