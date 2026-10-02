// Test-only backend. Does not link IOKit and never touches hardware.
#include "SMCCore.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
struct OSSMC {int modes[2];};
OSSMCFailure os_smc_last_failure(OSSMC*s){return (OSSMCFailure){.stage=2,.mode=-1,.target=-1};}
OSSMC *os_smc_open(void){return calloc(1,sizeof(OSSMC));}
void os_smc_close(OSSMC *s){free(s);}
int os_smc_read(OSSMC *s,const char *k,double *v){
 if(!strcmp(k,"FNum")){*v=2;return 0;}
 if(!strcmp(k,"#KEY")){*v=1;return 0;}
 if(!strcmp(k,"Tp01")){*v=getenv("FAIL_TEMP")?-1:70;return 0;}
 if(k[0]=='F'&&(k[1]=='0'||k[1]=='1')){
  if(!strcmp(k+2,"Md")){*v=getenv("EXTERNAL")?1:s->modes[k[1]-'0'];return 0;}
  if(!strcmp(k+2,"Mn")){*v=1200;return 0;}
  if(!strcmp(k+2,"Mx")){*v=6000;return 0;}
 }
 return -1;
}
int os_smc_key(OSSMC*s,uint32_t i,char key[5]){memcpy(key,"Tp01",5);return 0;}
int os_smc_fan_auto(OSSMC*s,int fan){s->modes[fan]=0;printf("AUTO %d\n",fan);fflush(stdout);return getenv("FAIL_RESTORE")?-1:0;}
int os_smc_fan_set(OSSMC*s,int fan,double rpm){s->modes[fan]=1;printf("SET %d %.0f\n",fan,rpm);fflush(stdout);return getenv("FAIL_WRITE")&&fan==1?-1:0;}
