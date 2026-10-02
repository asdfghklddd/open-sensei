import os,socket,subprocess,tempfile,time,signal,sys
helper=sys.argv[1]
def run(case,extra=None):
    with tempfile.TemporaryDirectory(prefix='OpenSensei-Fan-',dir='/private/tmp') as directory:
        path=directory+'/session.sock'
        listener=socket.socket(socket.AF_UNIX);listener.bind(path);os.chmod(path,0o600);listener.listen(1);listener.settimeout(4)
        env=os.environ.copy();env.update(extra or {})
        p=subprocess.Popen([helper,path,str(os.getuid()),'10','40',str(int(case=='curve'))],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        conn,_=listener.accept();conn.settimeout(10)
        stream=conn.makefile('r');first=stream.readline().strip()
        if extra and ('EXTERNAL'in extra or 'FAIL_TEMP'in extra):
            assert first.startswith('ERROR unsupported'),first
        else:
            assert first=='READY',first
            conn.sendall(b'P')
            reply=stream.readline().strip()
            if not(extra and 'FAIL_WRITE'in extra):assert reply.startswith('ACTIVE'),reply
            if case in ('disconnect','curve'):conn.shutdown(socket.SHUT_WR)
            elif case=='signal':p.send_signal(signal.SIGTERM)
            elif case=='deadline':
                # Renew the lease long enough for the hard session deadline.
                for _ in range(6):
                    try:conn.sendall(b'P')
                    except BrokenPipeError:break
                    time.sleep(2)
            elif case=='watchdog':pass
            elif case=='failed_restore':conn.shutdown(socket.SHUT_WR)
            replies=reply+'\n'+stream.read()
            if case=='failed_restore':assert 'restore failed' in replies,replies
            elif case=='failed_write':assert 'control failed; restored' in replies,replies
            else:assert 'RESTORED' in replies,replies
        out,err=p.communicate(timeout=4)
        conn.close();listener.close()
        if extra and ('EXTERNAL'in extra or 'FAIL_TEMP'in extra):assert 'SET' not in out,out
        else:
            assert 'SET 0' in out and 'AUTO 0' in out and 'AUTO 1' in out,out
        if case=='curve':assert 'ACTIVE curve' in replies and 'SET 0 4560' in out,(replies,out)
        print('PASS',case,flush=True)
for name,env in [('disconnect',None),('curve',None),('signal',None),('failed_write',{'FAIL_WRITE':'1'}),('failed_restore',{'FAIL_RESTORE':'1'}),('external_controller',{'EXTERNAL':'1'}),('no_temperature',{'FAIL_TEMP':'1'}),('watchdog',None),('deadline',None)]:run(name,env)
