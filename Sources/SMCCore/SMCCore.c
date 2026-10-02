// AppleSMC wire layout and numeric decoding adapted from asdfghklddd/fanctl (MIT).
// See THIRD_PARTY_NOTICES.txt. Connections belong to a single serial caller.
#include "SMCCore.h"
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
typedef struct { char major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } PLimit;
typedef struct { uint32_t size, type; char attributes; } KeyInfo;
typedef struct { uint32_t key; Version version; PLimit limit; KeyInfo info; char result, status, command; uint32_t index; unsigned char bytes[32]; } Packet;
_Static_assert(sizeof(Packet) == 80, "AppleSMC packet layout mismatch");
#define META_LIMIT 256
// Cache schema, never measured values. Each serial connection owns a bounded cache.
typedef struct { uint32_t key; KeyInfo info; double retryAt; int state; } MetaEntry;
struct OSSMC { io_connect_t connection; MetaEntry metadata[META_LIMIT]; unsigned cursor; OSSMCStatistics stats; kern_return_t lastKernel; unsigned lastFirmware, lastSize; OSSMCFailure failure; };
static double uptime(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static MetaEntry *metadata_entry(OSSMC *s,uint32_t key) {
    for(unsigned i=0;i<META_LIMIT;i++)if(s->metadata[i].state && s->metadata[i].key==key)return &s->metadata[i];
    MetaEntry *entry=&s->metadata[s->cursor++ % META_LIMIT]; memset(entry,0,sizeof(*entry)); entry->key=key; return entry;
}
static void invalidate(OSSMC *s,uint32_t key) { if(s)metadata_entry(s,key)->state=0; }
OSSMCStatistics os_smc_statistics(OSSMC *s) { return s ? s->stats : (OSSMCStatistics){0}; }
OSSMCFailure os_smc_last_failure(OSSMC *s) { return s ? s->failure : (OSSMCFailure){0}; }
static uint32_t code(const char *s) { return (uint32_t)(unsigned char)s[0]<<24 | (uint32_t)(unsigned char)s[1]<<16 | (uint32_t)(unsigned char)s[2]<<8 | (unsigned char)s[3]; }
static int call(OSSMC *s, Packet *in, Packet *out) {
    if (!s) return -1;
    s->stats.calls++;
    size_t size=sizeof(*out);
    s->lastKernel=IOConnectCallStructMethod(s->connection,2,in,sizeof(*in),out,&size); s->lastFirmware=(unsigned char)out->result; s->lastSize=(unsigned)size;
    return s->lastKernel==KERN_SUCCESS && size==sizeof(*out) && out->result==0 ? 0 : -1;
}
static int info(OSSMC *s, const char *key, KeyInfo *v) {
    if (!s || !key || strlen(key)!=4) return -1;
    uint32_t id=code(key); MetaEntry *entry=metadata_entry(s,id);
    if(entry->state==1) { s->stats.metadataHits++; *v=entry->info; return 0; }
    if(entry->state==-1 && uptime()<entry->retryAt) { s->stats.metadataHits++; return -1; }
    s->stats.metadataMisses++;
    Packet in={0},out={0}; in.key=id; in.command=9;
    if (call(s,&in,&out) || out.info.size==0 || out.info.size>32) {
        entry->state=-1; entry->retryAt=uptime()+60; return -1;
    }
    entry->info=out.info; entry->state=1; *v=out.info; return 0;
}
OSSMC *os_smc_open(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    OSSMC *s=calloc(1,sizeof(*s));
    if (!s) { IOObjectRelease(service); return NULL; }
    kern_return_t kr=IOServiceOpen(service,mach_task_self(),0,&s->connection); IOObjectRelease(service);
    if (kr!=KERN_SUCCESS) { free(s); return NULL; } return s;
}
void os_smc_close(OSSMC *s) { if (s) { IOServiceClose(s->connection); free(s); } }
int os_smc_read(OSSMC *s,const char *key,double *value) {
    KeyInfo ki; if (info(s,key,&ki)) return -1;
    Packet in={0},out={0}; in.key=code(key); in.info.size=ki.size; in.command=5;
    if (call(s,&in,&out)) { invalidate(s,in.key); return -1; }
    unsigned char *b=out.bytes; double v;
    if (ki.type==code("flt ") && ki.size==4) { float f; memcpy(&f,b,4); v=f; }
    else if ((ki.type==code("ui8 ") || ki.type==code("flag")) && ki.size==1) v=b[0];
    else if (ki.type==code("ui16") && ki.size==2) v=(b[0]<<8)|b[1];
    else if (ki.type==code("ui32") && ki.size==4) v=(uint32_t)b[0]<<24 | (uint32_t)b[1]<<16 | (uint32_t)b[2]<<8 | b[3];
    else if (ki.type==code("fpe2") && ki.size==2) v=((b[0]<<8)|b[1])/4.0;
    else if (ki.type==code("sp78") && ki.size==2) v=(int16_t)((b[0]<<8)|b[1])/256.0;
    else return -1;
    if (!isfinite(v)) return -1;
    *value=v; return 0;
}
int os_smc_key(OSSMC *s,uint32_t index,char key[5]) {
    Packet in={0},out={0}; in.command=8; in.index=index;
    if (call(s,&in,&out)) return -1;
    for (int i=0;i<4;i++) key[i]=(out.key>>(24-i*8))&255;
    key[4]=0; return 0;
}
static int write_value(OSSMC *s,const char *key,double value) {
    if (!isfinite(value)) return -1;
    KeyInfo ki; if (info(s,key,&ki)) return -1;
    Packet in={0},out={0}; in.key=code(key); in.info.size=ki.size; in.command=6;
    if (ki.type==code("flt ") && ki.size==4) { float f=value; memcpy(in.bytes,&f,4); }
    else if ((ki.type==code("ui8 ") || ki.type==code("flag")) && ki.size==1 && value>=0 && value<=255) in.bytes[0]=(unsigned char)value;
    else if (ki.type==code("fpe2") && ki.size==2 && value>=0 && value<16384) { uint16_t v=value*4; in.bytes[0]=v>>8; in.bytes[1]=v&255; }
    else return -1;
    int result=call(s,&in,&out); if(result)invalidate(s,in.key); return result;
}
static int verify_fan(OSSMC *s,const char *modeKey,const char *targetKey,double rpm,double *mode,double *target) {
    // A successful SMC write can precede its readable state. Only poll here;
    // never reassert control over a system/external override. Bound settling to 1 s.
    for(int attempt=0;attempt<=10;attempt++) {
        *mode=*target=-1;
        if(!os_smc_read(s,modeKey,mode) && !os_smc_read(s,targetKey,target) && *mode==1 && fabs(*target-rpm)<=20)return 0;
        if(attempt<10) { struct timespec pause={0,100000000}; nanosleep(&pause,NULL); }
    }
    return -1;
}
int os_smc_fan_auto(OSSMC *s,int fan) {
    if (fan<0 || fan>7) return -1;
    char key[5]={'F',(char)('0'+fan),'M','d',0};
    if (write_value(s,key,0)) return -1;
    double mode; return os_smc_read(s,key,&mode)==0 && (mode==0 || mode==3) ? 0 : -1;
}
int os_smc_fan_set(OSSMC *s,int fan,double rpm) {
    if (!s || fan<0 || fan>7 || !isfinite(rpm)) return -1;
    s->failure=(OSSMCFailure){.mode=-1,.target=-1};
    char mn[5]={'F',(char)('0'+fan),'M','n',0}, mx[5]={'F',(char)('0'+fan),'M','x',0};
    char md[5]={'F',(char)('0'+fan),'M','d',0}, tg[5]={'F',(char)('0'+fan),'T','g',0};
    double low,high; if (os_smc_read(s,mn,&low) || os_smc_read(s,mx,&high) || low<0 || high<=low || high>20000 || rpm<low || rpm>high) return -1;
    // Validate target support before entering forced mode. Any partial write is rolled back.
    KeyInfo targetInfo; if (info(s,tg,&targetInfo)) return -1;
    if (write_value(s,md,1)) {
        s->failure=(OSSMCFailure){.stage=1,.kernelStatus=s->lastKernel,.firmwareStatus=s->lastFirmware,.responseSize=s->lastSize,.mode=-1,.target=-1};
        os_smc_fan_auto(s,fan); return -1;
    }
    if (write_value(s,tg,rpm)) {
        s->failure=(OSSMCFailure){.stage=2,.kernelStatus=s->lastKernel,.firmwareStatus=s->lastFirmware,.responseSize=s->lastSize,.mode=-1,.target=-1};
        os_smc_fan_auto(s,fan); return -1;
    }
    double actualMode,target;
    actualMode=target=-1;
    if (verify_fan(s,md,tg,rpm,&actualMode,&target)) {
        s->failure=(OSSMCFailure){.stage=3,.kernelStatus=s->lastKernel,.firmwareStatus=s->lastFirmware,.responseSize=s->lastSize,.mode=actualMode,.target=target};
        os_smc_fan_auto(s,fan); return -1;
    }
    return 0;
}

// Apple Silicon battery cell integers use native little endian (Asahi macsmc).
// Keep this explicit: legacy macOS SMC keys such as #KEY use big endian.
int os_smc_read_le16(OSSMC *s,const char *key,double *value) {
    KeyInfo ki; if (info(s,key,&ki) || ki.size!=2 || ki.type!=code("ui16")) return -1;
    Packet in={0},out={0}; in.key=code(key); in.info.size=2; in.command=5;
    if (call(s,&in,&out)) { invalidate(s,in.key); return -1; }
    *value=out.bytes[0] | ((uint16_t)out.bytes[1]<<8); return 0;
}
