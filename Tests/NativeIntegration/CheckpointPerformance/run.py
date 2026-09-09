import pathlib,subprocess,tempfile,sys,json,os,time
root=pathlib.Path(__file__).resolve().parent
count=int(sys.argv[1]) if len(sys.argv)>1 else 1
assert count in (1,3)
(root/'runs').mkdir(exist_ok=True)
run=pathlib.Path(tempfile.mkdtemp(prefix='run.',dir=root/'runs'))
print(run.relative_to(root),flush=True)
failures=0
for pair in range(count):
 directory=run/f'pair-{pair}'
 directory.mkdir()
 state=directory/'state';state.mkdir()
 file=directory/'synthetic.txt'
 chunk=b'ordinary synthetic checkpoint latency text with bounded lines\n'*1024
 remaining=100_000_000
 with file.open('wb') as stream:
  while remaining:
   part=chunk[:min(len(chunk),remaining)];stream.write(part);remaining-=len(part)
 for mode in ('write','restore'):
  with (directory/f'{mode}.log').open('wb') as output:
   child=subprocess.Popen([str(root/'probe'),mode,str(state),str(file)],stdout=output,stderr=subprocess.STDOUT)
   began=time.monotonic()
   try:code=child.wait(timeout=60);result={'exit':code,'seconds':time.monotonic()-began}
   except subprocess.TimeoutExpired:
    child.kill();child.wait();code=124;result={'timeout':60,'killed_and_reaped':True,'seconds':time.monotonic()-began}
  (directory/f'{mode}-result.json').write_text(json.dumps(result)+'\n')
  print(pair,mode,json.dumps(result),flush=True)
  if code!=0:failures+=1;break
sys.exit(1 if failures else 0)
