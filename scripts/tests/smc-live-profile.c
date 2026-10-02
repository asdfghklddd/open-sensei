// Read-only comparison of the same live keys with and without schema reuse.
// No fan write function is called. The uncached pass clears only the in-RAM cache.
#include "../../Sources/SMCCore/SMCCore.c"
#include <stdio.h>
static double cpu_time(void) { struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t); return t.tv_sec+t.tv_nsec/1e9; }
int main(void) {
    OSSMC *s=os_smc_open(); if(!s) { fprintf(stderr,"SMC unavailable\n"); return 1; }
    char keys[128][5]; int count=0; double total=0,v=0;
    if(os_smc_read(s,"#KEY",&total) || total<1 || total>40000) { os_smc_close(s); return 1; }
    for(int i=0;i<(int)total && count<128;i++) {
        char key[5]; if(os_smc_key(s,i,key))continue;
        if(key[0]!='T' || !strchr("pgcCBb",key[1]))continue;
        if(!os_smc_read(s,key,&v) && v>=5 && v<=125)memcpy(keys[count++],key,5);
    }
    if(!count) { os_smc_close(s); return 1; }
    for(int pass=0;pass<6;pass++) {
        int cached=pass%2;
        for(int i=0;i<count;i++)os_smc_read(s,keys[i],&v);
        uint64_t calls=s->stats.calls; double start=uptime(),cpu=cpu_time(); int valid=0;
        for(int round=0;round<100;round++)for(int i=0;i<count;i++) {
            if(!cached)memset(s->metadata,0,sizeof(s->metadata));
            if(!os_smc_read(s,keys[i],&v))valid++;
        }
        printf("{\"schemaCache\":%s,\"keys\":%d,\"rounds\":100,\"valid\":%d,\"smcCalls\":%llu,\"wallSeconds\":%.6f,\"cpuSeconds\":%.6f}\n",cached?"true":"false",count,valid,(unsigned long long)(s->stats.calls-calls),uptime()-start,cpu_time()-cpu);
    }
    os_smc_close(s); return 0;
}
