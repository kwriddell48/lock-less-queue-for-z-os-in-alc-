#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include <time.h>
#include "qcall.h"
/* SLOW CALLBACK. EIGHT PRODUCERS PUSH 2000.    */
/* THE PENDING SUM MUST BE 2000 AND THE MAX     */
/* GREATER THAN 1. THEN STOP WHILE FOUR         */
/* PRODUCERS AND THE CALLBACK ARE STILL ACTIVE. */
#define NPROD 8
#define EACH 250
#define NTOT (NPROD*EACH)
#pragma linkage(SLOWCB,OS)
extern void SLOWCB(void);
typedef struct {
  volatile int calls;
  volatile int sum;
  volatile int maxp;
  volatile int spinms;
  unsigned long long t0;
  unsigned long long t1;
} slowctx;
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static volatile int gstop;
static slowctx gctx;
typedef struct {
  int id;
  int n;
} parg;
static void *
prod(void *arg)
{
  parg *p;
  int i;
  int rc;
  char src[4];
  p=(parg *)arg;
  src[0]=(char)p->id;
  for(i=0;i<p->n;i++){
    if(gstop)
      break;
    rc=mqenq(gq,src,1);
    if(rc){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      break;
    }
  }
  return 0;
}
static int
wait_sum(int want,int secs)
{
  time_t t;
  t=time(0);
  while(gctx.sum<want){
    if(time(0)>t+secs)
      return 1;
  }
  return 0;
}
static int
drain(void *q,int n)
{
  int rc;
  int i;
  unsigned out;
  char dst[4];
  for(i=0;i<n;i++){
    out=0;
    rc=mqdeq(q,dst,sizeof dst,&out);
    if(rc==RC_EMPTY)
      return i;
    if(rc!=RC_OK)
      return -1;
  }
  return n;
}
int
main(void)
{
  static unsigned char raw1[1600];
  static unsigned char raw2[1600];
  static parg wave1[NPROD];
  static parg wave2[4];
  const char *who;
  pthread_t tp[NPROD];
  void *q;
  void *ep;
  int rc;
  int i;
  int got;
  int nd;
  time_t t;
  who="T23NTFST";
  mqwhen(who,"START");
  ep=(void *)SLOWCB;
  q=mqalign(raw1,sizeof raw1);
  if(q==0)
    return mqfail(who,"align");
  memset(&gctx,0,sizeof gctx);
  gctx.spinms=50;
  gq=q;
  gbad=0;
  gstop=0;
  rc=mqinit(q,0,NTOT,ep,&gctx,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  got=0;
  for(i=0;i<NPROD;i++){
    wave1[i].id=i;
    wave1[i].n=EACH;
    rc=pthread_create(&tp[i],0,prod,&wave1[i]);
    if(rc){
      gbad=1;
      break;
    }
    got++;
  }
  for(i=0;i<got;i++)
    pthread_join(tp[i],0);
  if(gbad){
    mqshow(who,q);
    return mqfail(who,"prod");
  }
  if(wait_sum(NTOT,180)){
    mqshow(who,q);
    return mqfailn(who,"sum",gctx.sum);
  }
  if(gctx.maxp<2){
    mqshow(who,q);
    return mqfailn(who,"max",gctx.maxp);
  }
  rc=mqstop(q);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stop",rc);
  }
  nd=drain(q,NTOT);
  if(nd!=NTOT){
    mqshow(who,q);
    return mqfailn(who,"drain",nd);
  }
  q=mqalign(raw2,sizeof raw2);
  if(q==0)
    return mqfail(who,"align2");
  memset(&gctx,0,sizeof gctx);
  gctx.spinms=50;
  gq=q;
  gbad=0;
  gstop=0;
  rc=mqinit(q,0,512,ep,&gctx,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init2",rc);
  got=0;
  for(i=0;i<4;i++){
    wave2[i].id=i;
    wave2[i].n=2000;
    rc=pthread_create(&tp[i],0,prod,&wave2[i]);
    if(rc){
      gbad=1;
      break;
    }
    got++;
  }
  t=time(0);
  while(gctx.calls<1 && time(0)<t+30)
    ;
  rc=mqstop(q);
  gstop=1;
  for(i=0;i<got;i++)
    pthread_join(tp[i],0);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stop2",rc);
  }
  nd=drain(q,8000);
  if(nd<0){
    mqshow(who,q);
    return mqfail(who,"drain2");
  }
  rc=mqenq(q,"Z",1);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"after",rc);
  }
  nd=drain(q,1);
  mqshow(who,q);
  if(nd!=1)
    return mqfail(who,"alive");
  return mqpass(who);
}
