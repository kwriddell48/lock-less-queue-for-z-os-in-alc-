#include "qcall.h"
#include <time.h>
/* EACH CALL PASSES A 128-BYTE BUFFER. QSTUB USES IT  */
/* AS THE SAVE AREA AND PUTS THE VALUE LIST AT +96.   */
void *
mqalign(unsigned char *raw,unsigned n)
{
  unsigned long p;
  unsigned long a;
  unsigned long need;
  if(raw==0)
    return 0;
  p=(unsigned long)raw;
  a=(p+255UL)&~255UL;
  need=(unsigned long)QCB_SIZE;
  if(a<p || a+need<a)
    return 0;
  if(a+need>p+(unsigned long)n)
    return 0;
  return (void *)a;
}
int
mqinit(void *qcb,int opt,int pool,
       void *cb,void *ctx,void *ecb)
{
  void *pq;
  void *pcb;
  void *pcx;
  void *pec;
  void *pw;
  int o;
  int p;
  unsigned char work[128];
  pq=qcb;
  o=opt;
  p=pool;
  pcb=cb;
  pcx=ctx;
  pec=ecb;
  pw=work;
  return QINITC(&pq,&o,&p,&pcb,&pcx,&pec,&pw);
}
int
mqenq(void *qcb,void *src,unsigned n)
{
  void *pq;
  void *ps;
  void *pw;
  unsigned nn;
  unsigned char work[128];
  pq=qcb;
  ps=src;
  nn=n;
  pw=work;
  return QENQC(&pq,&ps,&nn,&pw);
}
int
mqdeq(void *qcb,void *dst,unsigned n,
      unsigned *out)
{
  void *pq;
  void *pd;
  void *pw;
  unsigned nn;
  unsigned *po;
  unsigned char work[128];
  pq=qcb;
  pd=dst;
  nn=n;
  po=out;
  pw=work;
  return QDEQC(&pq,&pd,&nn,&po,&pw);
}
int
mqstats(void *qcb,mqstat *out,unsigned n)
{
  void *pq;
  void *pw;
  mqstat *po;
  unsigned nn;
  unsigned char work[128];
  pq=qcb;
  po=out;
  nn=n;
  pw=work;
  return QSTATC(&pq,&po,&nn,&pw);
}
void
mqshow(const char *who,void *qcb)
{
  mqstat st;
  int rc;
  if(qcb==0)
    return;
  memset(&st,0,sizeof st);
  rc=mqstats(qcb,&st,(unsigned)sizeof st);
  if(rc!=RC_OK){
    printf("%s STAT rc %d\n",who,rc);
    fflush(stdout);
    return;
  }
  printf("%s STAT enq %d deq %d mt %d\n",
         who,st.enq_ok,st.deq_ok,
         st.deq_empty);
  printf("%s STAT afail %d eret %d dret %d\n",
         who,st.enq_fail,st.enq_retry,
         st.deq_retry);
  printf("%s STAT pret %d sret %d\n",
         who,st.pop_retry,st.psh_retry);
  printf("%s STAT dep %d dmax %d\n",
         who,st.depth,st.depth_max);
  printf("%s STAT pay %u %u\n",
         who,st.pay_hi,st.pay_lo);
  printf("%s STAT pmax %u %u\n",
         who,st.max_hi,st.max_lo);
  printf("%s STAT ipost %d upost %d\n",
         who,st.post_int,st.post_usr);
  printf("%s STAT cb %d cmax %d\n",
         who,st.cb_calls,st.cb_max);
  fflush(stdout);
}
int
mqstop(void *qcb)
{
  void *pq;
  void *pw;
  unsigned char work[128];
  pq=qcb;
  pw=work;
  return QSTOPC(&pq,&pw);
}
void
mqwait(unsigned *ecb)
{
  unsigned *p;
  /* OS LIST HOLDS &P. THE STUB LOADS P, THE ECB. */
  p=ecb;
  WAITECB(&p);
}
void
mqwhen(const char *who,const char *what)
{
  time_t t;
  struct tm *p;
  char b[12];
  t=time(0);
  p=localtime(&t);
  if(p==0){
    b[0]='?';
    b[1]=0;
  }else
    strftime(b,12,"%H:%M:%S",p);
  printf("%s %s %s\n",who,b,what);
  fflush(stdout);
}
int
mqfail(const char *who,const char *why)
{
  mqwhen(who,"END");
  printf("%s FAIL %s\n",who,why);
  return 1;
}
int
mqfailn(const char *who,const char *why,int n)
{
  mqwhen(who,"END");
  printf("%s FAIL %s %d\n",who,why,n);
  return 1;
}
int
mqpass(const char *who)
{
  mqwhen(who,"END");
  printf("%s PASS\n",who);
  return 0;
}
