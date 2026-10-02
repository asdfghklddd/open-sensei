// Exercise the real packet encoder and rollback path with an in-memory device.
// IOConnectCallStructMethod is replaced; no SMC connection or hardware writes occur.
#include <IOKit/IOKitLib.h>
static kern_return_t mocked(mach_port_t,uint32_t,const void*,size_t,void*,size_t*);
#define IOConnectCallStructMethod mocked
#include "../../Sources/SMCCore/SMCCore.c"
#include <assert.h>
#include <stdio.h>

static int mode, writes, modeFailure, targetFailure, missingTarget, wrongTarget, shortWrite, settling, pending;
static float target;
static kern_return_t mocked(mach_port_t connection,uint32_t selector,const void *input,size_t n,void *output,size_t *length) {
    const Packet *in=input; Packet *out=output;
    memset(out,0,sizeof(*out)); *length=sizeof(*out);
    int md=in->key==code("F0Md"), tg=in->key==code("F0Tg");
    if(in->command==9) {
        if(tg && missingTarget) { out->result=(char)132; return KERN_SUCCESS; }
        out->info.size=md?1:4; out->info.type=code(md?"ui8 ":"flt ");
    } else if(in->command==5) {
        if(md) { if(pending>0 && --pending==0)mode=1; out->bytes[0]=mode; }
        else {
            float value=in->key==code("F0Mn")?1200:in->key==code("F0Mx")?6000:target-(wrongTarget?200:0);
            memcpy(out->bytes,&value,4);
        }
    } else if(in->command==6) {
        writes++;
        if((md && in->bytes[0]==1 && modeFailure) || (tg && targetFailure)) { out->result=(char)132; return KERN_SUCCESS; }
        if(md) { if(in->bytes[0]==1 && settling)pending=4; else { mode=in->bytes[0]; pending=0; } }
        else if(tg)memcpy(&target,in->bytes,4);
        if(tg && shortWrite)*length=0;
    }
    return KERN_SUCCESS;
}
static OSSMC reset(void) {
    mode=writes=modeFailure=targetFailure=missingTarget=wrongTarget=shortWrite=settling=pending=0; target=0;
    return (OSSMC){0};
}
int main(void) {
    OSSMC s=reset();
    assert(!os_smc_fan_set(&s,0,3120) && mode==1 && target==3120);
    assert(!os_smc_fan_auto(&s,0) && mode==0);
    s=reset(); assert(os_smc_fan_set(&s,0,7000) && !writes);
    assert(os_smc_fan_set(&s,0,NAN) && !writes);
    s=reset(); missingTarget=1; assert(os_smc_fan_set(&s,0,3120) && !writes);
    s=reset(); modeFailure=1;
    assert(os_smc_fan_set(&s,0,3120) && mode==0);
    assert(s.failure.stage==1 && s.failure.firmwareStatus==132);
    s=reset(); targetFailure=1;
    assert(os_smc_fan_set(&s,0,3120) && mode==0);
    assert(s.failure.stage==2 && s.failure.firmwareStatus==132);
    s=reset(); wrongTarget=1;
    assert(os_smc_fan_set(&s,0,3120) && mode==0);
    assert(s.failure.stage==3 && s.failure.mode==1 && s.failure.target==2920);
    s=reset(); shortWrite=1;
    assert(os_smc_fan_set(&s,0,3120) && mode==0);
    assert(s.failure.stage==2 && s.failure.responseSize==0);
    s=reset(); settling=1;
    assert(!os_smc_fan_set(&s,0,3120) && mode==1 && target==3120 && writes==2);
    puts("PASS SMC fan bounds, encoding, preflight, stage diagnostics and partial-write rollback");
}
