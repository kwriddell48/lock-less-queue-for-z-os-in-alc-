#include "qcall.h"
#include <time.h>
/* NOTIFIER CALLS TSTCB. CTX IS CALLS, PENDING, ECB. */
/* EACH LINE IS FLUSHED SO A HANG SHOWS THE LAST ONE. */
typedef struct {
  volatile int calls;
  volatile int pending;
  volatile unsigned int ecb;
} cbblk;
static void
stamp(char *b)
{
  time_t t;
  struct tm *p;
  t=time(0);
  p=localtime(&t);
  if(p==0){
    b[0]='?';
    b[1]=0;
    return;
  }
  strftime(b,12,"%H:%M:%S",p);
}
static void
say(const char *m)
{
  char b[12];
  stamp(b);
  printf("T07CB %s %s\n",b,m);
  fflush(stdout);
}
static void
sayn(const char *m,int n)
{
  char b[12];
  stamp(b);
  printf("T07CB %s %s %d\n",b,m,n);
  fflush(stdout);
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  void *ep;
  cbblk blk;
  mqstat st;
  int rc;
  int i;
  char src[4];
  who="T07CB";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  say("aligned");
  memset(&blk,0,sizeof blk);
  ep=(void *)TSTCB;
  say("init");
  rc=mqinit(q,0,8,ep,&blk,0);
  sayn("initrc",rc);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  for(i=0;i<3;i++){
    src[0]=(char)('A'+i);
    sayn("enq",i);
    rc=mqenq(q,src,1);
    sayn("enqrc",rc);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"enq",rc);
    }
  }
  memset(&st,0,sizeof st);
  say("stat");
  rc=mqstats(q,&st,(unsigned)sizeof st);
  sayn("statrc",rc);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  sayn("enqok",st.enq_ok);
  sayn("post",st.post_int);
  if(st.enq_ok!=3 || st.post_int!=3){
    mqshow(who,q);
    return mqfail(who,"post");
  }
  say("wait");
  mqwait((unsigned *)&blk.ecb);
  sayn("calls",blk.calls);
  sayn("pend",blk.pending);
  if(blk.calls<1 || blk.calls>3){
    mqshow(who,q);
    return mqfailn(who,"calls",blk.calls);
  }
  if(blk.pending<1){
    mqshow(who,q);
    return mqfail(who,"pending");
  }
  memset(&st,0,sizeof st);
  say("stat2");
  rc=mqstats(q,&st,(unsigned)sizeof st);
  sayn("stat2rc",rc);
  if(rc!=RC_OK)
    return mqfailn(who,"stat2",rc);
  sayn("cb",st.cb_calls);
  if(st.cb_calls<1){
    mqshow(who,q);
    return mqfail(who,"cb");
  }
  say("stop");
  rc=mqstop(q);
  sayn("stoprc",rc);
  mqshow(who,q);
  if(rc!=RC_OK)
    return mqfailn(who,"stop",rc);
  return mqpass(who);
}
