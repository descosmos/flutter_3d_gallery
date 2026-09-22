#!/usr/bin/env python3
import argparse,os,re,shutil,subprocess,time
from pathlib import Path
parser=argparse.ArgumentParser(description='连接当前设备上的 profile 集成测试包并读取结果。先构建 app-profile.apk。')
parser.add_argument('--serial',required=True)
parser.add_argument('--apk',type=Path,help='指定已构建的 GPU 集成测试 profile APK')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
adb=['adb','-s',args.serial]
app='com.example.flutter_3d_demo'
subprocess.run(adb+['install','-r',str(args.apk or root/'build/app/outputs/flutter-apk/app-profile.apk')],check=True)
subprocess.run(adb+['shell','am','force-stop',app],check=True)
subprocess.run(adb+['shell','am','start','-W','-n',app+'/.MainActivity'],check=True)
url=None
for _ in range(30):
 pid=subprocess.check_output(adb+['shell','pidof',app],text=True).strip()
 if pid:
  log=subprocess.check_output(adb+['logcat','-d',f'--pid={pid}','-s','flutter:I'],text=True)
  match=re.search(r'The Dart VM service is listening on http://127.0.0.1:(\d+)/(\S+)',log)
  if match:
   port=subprocess.check_output(adb+['forward','tcp:0','tcp:'+match[1]],text=True).strip()
   url='http://127.0.0.1:'+port+'/'+match[2]
   break
 time.sleep(1)
if not url: raise RuntimeError('Live app did not expose a VM service')
env=os.environ.copy()
for key in ['http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','all_proxy']: env.pop(key,None)
env['VM_SERVICE_URL']=url
try:
 result=subprocess.run([str(Path(shutil.which('flutter')).resolve().parent/'dart'),str(root/'test_driver/gpu_scene_test.dart')],cwd=root,env=env,timeout=120)
 log=subprocess.check_output(adb+['logcat','-d',f'--pid={pid}','-s','flutter:I'],text=True)
 (root/'build/gpu-native-test-log.txt').write_text(re.sub(r'http://127\.0\.0\.1:\d+/\S+', '[VM service]',log))
 raise SystemExit(result.returncode)
finally:
 subprocess.run(adb+['forward','--remove','tcp:'+port])
