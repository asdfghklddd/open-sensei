#include <IOKit/IOKitLib.h>
static kern_return_t mocked(mach_port_t,uint32_t,const void*,size_t,void*,size_t*);
#define IOConnectCallStructMethod mocked
#include "../../Sources/SMCCore/SMCCore.c"
#include <assert.h>
#include <stdio.h>
static float reading=45;
static int badRead=0, missing=0;
static kern_return_t mocked(mach_port_t connection,uint32_t selector,const void *input,size_t n,void *output,size_t *length) {
    const Packet *in=input; Packet *out=output; memset(out,0,sizeof(*out)); *length=sizeof(*out);
    if(in->command==9) {
        if(missing) { out->result=1; return KERN_SUCCESS; }
        out->info.size=4; out->info.type=code("flt ");
    } else if(in->command==5) {
        if(badRead)out->result=1; else memcpy(out->bytes,&reading,4);
    }
    return KERN_SUCCESS;
}
int main(void) {
    OSSMC s={0}; double value;
    assert(os_smc_read(&s,"Tp01",&value)==0 && value==45);
    assert(s.stats.calls==2);
    reading=52;
    assert(os_smc_read(&s,"Tp01",&value)==0 && value==52);
    assert(s.stats.calls==3 && s.stats.metadataHits==1); // schema cached, actual reading fresh
    badRead=1; assert(os_smc_read(&s,"Tp01",&value)!=0);
    badRead=0; assert(os_smc_read(&s,"Tp01",&value)==0);
    assert(s.stats.calls==6); // failed value read invalidates schema
    missing=1; assert(os_smc_read(&s,"ABCD",&value)!=0);
    uint64_t before=s.stats.calls;
    assert(os_smc_read(&s,"ABCD",&value)!=0 && s.stats.calls==before);
    metadata_entry(&s,code("ABCD"))->retryAt=0;
    missing=0; assert(os_smc_read(&s,"ABCD",&value)==0 && s.stats.calls==before+2);
    for(unsigned i=0;i<1000;i++) { char key[5]; snprintf(key,5,"%04X",i); assert(os_smc_read(&s,key,&value)==0); }
    assert(s.cursor>=1000);
    assert(os_smc_read(&s,"Tp01",&value)==0);
    puts("PASS SMC schema cache, fresh values, error invalidation, missing-key backoff, bounded eviction");
}
