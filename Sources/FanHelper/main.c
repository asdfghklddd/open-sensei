// Bounded, on-demand fan session. No installed daemon, disk history or shell execution.
#include "SMCCore.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/poll.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <errno.h>

static volatile sig_atomic_t stopped=0;
static void stop_signal(int ignored) { stopped=1; }
static double monotime(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static int integer(const char *s,long min,long max,long *v) {
    char *end; errno=0; long n=strtol(s,&end,10);
    if (errno || !s[0] || *end || n<min || n>max) return -1; *v=n; return 0;
}
static double protected_target(double requested,double low,double high,double temperature) {
    if (!isfinite(requested)||!isfinite(low)||!isfinite(high)||!isfinite(temperature)||high<=low) return NAN;
    double cooling=fmin(1,fmax(0,(temperature-85)/10));
    return fmax(fmin(high,fmax(low,requested)),low+(high-low)*cooling);
}
typedef struct { double smoothed, held, previousTime; int ready; } CurveState;
static double curve_percent(CurveState *state,double temperature,double floor,double now) {
    if(!isfinite(temperature)||!isfinite(floor)||!isfinite(now)||floor<0||floor>100)return NAN;
    if(!state->ready) { state->smoothed=state->held=temperature; state->ready=1; }
    else {
        double dt=fmin(6,fmax(0,now-state->previousTime));
        state->smoothed+=(temperature-state->smoothed)*(1-exp(-dt/6));
        // Upward movement follows the smoothed reading; falling temperature has a 2 C band.
        if(state->smoothed>state->held)state->held=state->smoothed;
        else if(state->smoothed<state->held-2)state->held=state->smoothed+2;
    }
    state->previousTime=now;
    return floor+(100-floor)*fmin(1,fmax(0,(state->held-55)/30));
}
static double curve_target(double percent,double low,double high,double previous,double rawTemperature) {
    double wanted=low+(high-low)*percent/100;
    // Every tick is at least 2 s apart. Falling speed is limited to 2% of range per tick.
    if(previous>=0 && wanted<previous)wanted=fmax(wanted,previous-(high-low)*0.02);
    // Raw (unsmoothed) heat always has priority over smoothing and the downward ramp.
    return protected_target(wanted,low,high,rawTemperature);
}
static int send_text(int fd,const char *text) { return send(fd,text,strlen(text),0)==(ssize_t)strlen(text) ? 0 : -1; }
static int restore(OSSMC *s,int count,unsigned touched) {
    int success=1;
    for (int f=0;f<count;f++) if (touched & (1u<<f)) {
        int ok=0;
        for(int retry=0;retry<3;retry++) { if(!os_smc_fan_auto(s,f)) { ok=1; break; } usleep(100000); }
        if(!ok)success=0;
    }
    return success;
}
static int discover(OSSMC *s,char keys[128][5]) {
    double count=0; int n=0;
    if(os_smc_read(s,"#KEY",&count)||count<=0||count>40000)return 0;
    for(uint32_t i=0;i<(uint32_t)count&&n<128;i++) {
        char key[5]; double value;
        if(os_smc_key(s,i,key)||key[0]!='T'||!strchr("pgcC",key[1]))continue;
        if(!os_smc_read(s,key,&value)&&value>=5&&value<=125)memcpy(keys[n++],key,5);
    }
    return n;
}
static double temperature(OSSMC *s,char keys[128][5],int count) {
    double high=-1; int valid=0;
    for(int i=0;i<count;i++){double v;if(!os_smc_read(s,keys[i],&v)&&v>=5&&v<=125){valid++;high=fmax(high,v);}}
    return count>0&&valid*2>=count ? high : -1;
}

#ifdef HELPER_SELF_TEST
#include <assert.h>
int main(void) {
    long v=0;
    assert(!integer("600",1,1800,&v)&&v==600);
    assert(integer("601x",1,1800,&v)); assert(integer("-1",1,1800,&v)); assert(integer("999999999999999999999",1,1800,&v));
    assert(protected_target(2500,1200,6000,60)==2500);
    assert(protected_target(2500,1200,6000,90)==3600);
    assert(protected_target(2500,1200,6000,95)==6000);
    assert(protected_target(100000,1200,6000,50)==6000);
    assert(isnan(protected_target(NAN,1200,6000,50)));
    CurveState curve={0};
    assert(curve_percent(&curve,55,40,0)==40);
    double pulse=curve_percent(&curve,85,40,2);
    assert(pulse>40 && pulse<60); // One hot sample does not immediately saturate the curve.
    for(int i=2;i<30;i++)pulse=curve_percent(&curve,85,40,i*2);
    assert(pulse>99 && pulse<=100);
    double falling=curve_percent(&curve,55,40,60);
    assert(falling<pulse && falling>80);
    assert(curve_target(40,1200,6000,5000,55)==4904);
    assert(curve_target(40,1200,6000,5000,95)==6000);
    assert(isnan(curve_percent(&curve,NAN,40,62)));
    puts("Fan helper validation and thermal override tests passed."); return 0;
}
#else
int main(int argc,char **argv) {
    // Args fixed at session creation: socket, uid, duration, floor percentage, optional curve.
    long uid,seconds,percent,curveMode=0;
    if((argc!=5 && argc!=6) || integer(argv[2],1,INT32_MAX,&uid) || integer(argv[3],10,1800,&seconds) || integer(argv[4],0,100,&percent) || (argc==6 && integer(argv[5],0,1,&curveMode)))return 2;
    #ifndef FAN_HELPER_SIMULATOR
    if(geteuid()!=0){fprintf(stderr,"Fan control requires macOS administrator authorization.\n");return 3;}
    #endif
    // Verify the private directory and socket before connecting. No files are opened for writing.
    if(strncmp(argv[1],"/private/tmp/OpenSensei-Fan-",sizeof("/private/tmp/OpenSensei-Fan-")-1)!=0 || strlen(argv[1])>=sizeof(((struct sockaddr_un *)0)->sun_path))return 4;
    char parent[104];strlcpy(parent,argv[1],sizeof(parent));char *slash=strrchr(parent,'/');if(!slash)return 4;*slash=0;
    struct stat st;
    if(lstat(parent,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=(uid_t)uid||(st.st_mode&077)!=0)return 4;
    if(lstat(argv[1],&st)||!S_ISSOCK(st.st_mode)||st.st_uid!=(uid_t)uid||(st.st_mode&077)!=0)return 4;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return 4;
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;strlcpy(addr.sun_path,argv[1],sizeof(addr.sun_path));
    if(connect(fd,(struct sockaddr*)&addr,sizeof(addr))){close(fd);return 4;}
    uid_t peer;gid_t group;
    if(getpeereid(fd,&peer,&group)||peer!=(uid_t)uid){close(fd);return 4;}
    struct timeval timeout={2,0};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    signal(SIGTERM,stop_signal);signal(SIGINT,stop_signal);signal(SIGHUP,stop_signal);signal(SIGPIPE,SIG_IGN);
    OSSMC *smc=os_smc_open();double n=0;
    if(!smc||os_smc_read(smc,"FNum",&n)||n<1||n>8){send_text(fd,"ERROR SMC unavailable\n");os_smc_close(smc);close(fd);return 5;}
    int count=(int)n; double low[8],high[8],requested[8],last[8],ramp[8];unsigned touched=0;
    int failure=0,failedFan=-1;
    OSSMCFailure writeFailure={0};
    for(int f=0;f<count;f++) {
        char key[5];double mode;
        snprintf(key,5,"F%dMd",f);
        if(os_smc_read(smc,key,&mode)||!(mode==0||mode==3)){failure=1;break;}
        snprintf(key,5,"F%dMn",f);if(os_smc_read(smc,key,&low[f])){failure=1;break;}
        snprintf(key,5,"F%dMx",f);if(os_smc_read(smc,key,&high[f])){failure=1;break;}
        if(low[f]<0||high[f]<=low[f]||high[f]>20000){failure=1;break;}
        requested[f]=low[f]+(high[f]-low[f])*percent/100.0;last[f]=ramp[f]=-1;
    }
    char keys[128][5];int sensorCount=discover(smc,keys);
    if(failure || temperature(smc,keys,sensorCount)<0){send_text(fd,"ERROR unsupported or another controller active\n");os_smc_close(smc);close(fd);return 6;}
    if(send_text(fd,"READY\n")){os_smc_close(smc);close(fd);return 7;}
    double start=monotime(),heartbeat=start,lastTick=0;int activated=0;CurveState curve={0};
    while(!stopped && monotime()-start<seconds) {
        struct pollfd event={fd,POLLIN,0};int polled=poll(&event,1,1000);
        if(polled<0 && errno!=EINTR)break;
        if(event.revents&(POLLHUP|POLLERR|POLLNVAL))break;
        if(event.revents&POLLIN) {
            char b[32];ssize_t size=recv(fd,b,sizeof(b),0);if(size<=0)break;
            int valid=1;for(int i=0;i<size;i++)if(b[i]!='P')valid=0;
            if(!valid)break;heartbeat=monotime();activated=1;
        }
        double now=monotime();
        if(now-heartbeat>6)break; // The app dies, sleeps, stalls or disconnects: give control back.
        if(!activated||now-lastTick<2)continue;
        // A long scheduling gap (e.g. sleep) invalidates this session before any new writes.
        if(lastTick>0 && now-lastTick>6)break;
        lastTick=now;
        double temp=temperature(smc,keys,sensorCount);
        if(temp<0){failure=1;break;}
        double curvePercent=curveMode?curve_percent(&curve,temp,percent,now):percent;
        if(!isfinite(curvePercent)){failure=1;break;}
        for(int f=0;f<count;f++) {
            double rawTarget=curveMode?curve_target(curvePercent,low[f],high[f],ramp[f],temp):protected_target(requested[f],low[f],high[f],temp);
            ramp[f]=rawTarget; // Accumulate small downward steps even below the write deadband.
            double target=fmin(high[f],fmax(low[f],round(rawTarget)));
            // Do not repeatedly write if the target is unchanged, but detect external overrides.
            char key[5];double mode;snprintf(key,5,"F%dMd",f);
            if(last[f]>=0 && (os_smc_read(smc,key,&mode)||mode!=1)){failure=1;break;}
            if(last[f]<0||fabs(target-last[f])>=50) {
                touched|=1u<<f;
                if(os_smc_fan_set(smc,f,target)){failure=1;failedFan=f;writeFailure=os_smc_last_failure(smc);break;}
                last[f]=target;
            }
        }
        if(failure)break;
        if(send_text(fd,temp>=85 ? "ACTIVE thermal\n" : curveMode ? "ACTIVE curve\n" : "ACTIVE manual\n"))break;
    }
    int restored=restore(smc,count,touched);
    if(restored && failure && failedFan>=0) {
        char detail[200];snprintf(detail,sizeof(detail),"ERROR control failed; restored | fan=%d stage=%d io=0x%x smc=%u bytes=%u mode=%.0f target=%.0f\n",failedFan+1,writeFailure.stage,writeFailure.kernelStatus,writeFailure.firmwareStatus,writeFailure.responseSize,writeFailure.mode,writeFailure.target);
        send_text(fd,detail);
    } else send_text(fd,!restored ? "ERROR restore failed\n" : (failure ? "ERROR control failed; restored\n" : "RESTORED\n"));
    os_smc_close(smc);close(fd);
    return restored&&!failure ? 0 : 8;
}
#endif
