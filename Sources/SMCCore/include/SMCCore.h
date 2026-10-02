#ifndef OPEN_SENSEI_SMC_H
#define OPEN_SENSEI_SMC_H
#include <stdint.h>
typedef struct OSSMC OSSMC;
typedef struct { uint64_t calls, metadataHits, metadataMisses; } OSSMCStatistics;
typedef struct { int stage; uint32_t kernelStatus; unsigned firmwareStatus, responseSize; double mode, target; } OSSMCFailure;
OSSMCStatistics os_smc_statistics(OSSMC *smc);
OSSMCFailure os_smc_last_failure(OSSMC *smc);
OSSMC *os_smc_open(void);
void os_smc_close(OSSMC *smc);
int os_smc_read(OSSMC *smc, const char *key, double *value);
int os_smc_read_le16(OSSMC *smc, const char *key, double *value);
int os_smc_key(OSSMC *smc, uint32_t index, char key[5]);
int os_smc_fan_auto(OSSMC *smc, int fan);
int os_smc_fan_set(OSSMC *smc, int fan, double rpm);
#endif
