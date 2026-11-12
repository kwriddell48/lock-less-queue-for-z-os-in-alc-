#ifndef QCALL_H
#define QCALL_H
#include <stdio.h>
#include <string.h>
/* ILP32. QCB IS 1336 BYTES AND 256-ALIGNED.          */
/* STATS BLOCK IS 20 FULLWORDS (80 BYTES).            */
#define QCB_SIZE 1336
#define QCB_ALIGN 256
#define RC_OK 0
#define RC_EMPTY 4
#define RC_ALLOC 8
#define RC_TRUNC 8
#define RC_ALIGN 12
#define INLINE_MAX 1024
#define PAY31_MAX 65536
typedef struct {
  int version;
  int size;
  int enq_ok;
  int deq_ok;
  int deq_empty;
  int enq_fail;
  int enq_retry;
  int deq_retry;
  int pop_retry;
  int psh_retry;
  int depth;
  int depth_max;
  unsigned int pay_hi;
  unsigned int pay_lo;
  unsigned int max_hi;
  unsigned int max_lo;
  int post_int;
  int post_usr;
  int cb_calls;
  int cb_max;
} mqstat;
#pragma linkage(QINITC,OS)
extern int QINITC(void **,int *,int *,
                  void **,void **,void **,
                  void **);
#pragma linkage(QENQC,OS)
extern int QENQC(void **,void **,unsigned *,
                 void **);
#pragma linkage(QDEQC,OS)
extern int QDEQC(void **,void **,unsigned *,
                 unsigned **,void **);
#pragma linkage(QSTATC,OS)
extern int QSTATC(void **,mqstat **,
                  unsigned *,void **);
#pragma linkage(QSTOPC,OS)
extern int QSTOPC(void **,void **);
#pragma linkage(WAITECB,OS)
extern void WAITECB(unsigned **);
#pragma linkage(TSTCB,OS)
extern void TSTCB(void);
void *mqalign(unsigned char *raw,unsigned n);
int mqinit(void *qcb,int opt,int pool,
           void *cb,void *ctx,void *ecb);
int mqenq(void *qcb,void *src,unsigned n);
int mqdeq(void *qcb,void *dst,unsigned n,
          unsigned *out);
int mqstats(void *qcb,mqstat *out,unsigned n);
void mqshow(const char *who,void *qcb);
void mqwhen(const char *who,const char *what);
int mqstop(void *qcb);
void mqwait(unsigned *ecb);
int mqfail(const char *who,const char *why);
int mqfailn(const char *who,const char *why,
            int n);
int mqpass(const char *who);
#endif
