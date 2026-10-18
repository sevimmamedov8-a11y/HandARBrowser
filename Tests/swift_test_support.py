"""Compile and execute real Swift tests on macOS or an installed Windows SDK."""
from pathlib import Path
import os,shutil,subprocess,tempfile

def run_swift_sources(sources):
    compiler=shutil.which('swiftc')
    if compiler is None:
        raise RuntimeError('swiftc is required to run the native tests')
    flags=[]
    runtime_env=os.environ.copy()
    if os.name=='nt':
        root=Path(compiler).resolve().parents[4]
        sdks=sorted(root.glob('Platforms/*/Windows.platform/Developer/SDKs/Windows.sdk'))
        if sdks:
            flags=['-sdk',str(sdks[-1])]
        runtimes=sorted(root.glob('Runtimes/*/usr/bin'))
        if runtimes:
            runtime_env['PATH']=str(runtimes[-1])+os.pathsep+runtime_env.get('PATH','')
    with tempfile.TemporaryDirectory(prefix='handar-swift-tests-') as directory:
        executable=Path(directory)/('tests.exe' if os.name=='nt' else 'tests')
        subprocess.run([compiler,*flags,*map(str,sources),'-o',str(executable)],check=True,timeout=90)
        subprocess.run([str(executable)],check=True,timeout=30,env=runtime_env)
