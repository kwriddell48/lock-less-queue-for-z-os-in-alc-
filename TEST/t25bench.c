#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include <time.h>
#include "qcall.h"
/* FOUR SHAPES, 150000 MESSAGES EACH.            */
/* 1.2 MILLION ENQUEUE PLUS DEQUEUE CALLS.       */
/* THEN 32 NOTIFIER ENQUEUES ACROSS THE          */
/* UNSIGNED SEQUENCE WRAP.                       */
#define NMSG 150000
#define NWRAP 32
#pragma linkage(SLOWCB,OS)
extern void SLOWCB(void);
typedef struct {
  int id;
  int nmsg;
} parg;
typedef struct {
  int prod;
  int seq;
} rec_t;
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
static int gcount;
static int gtot;
static int glast[8];
static void *
prod(void *arg)
{
  parg *p;
  int s;
  int rc;
  rec_t rec;
  p=(parg *)arg;
  for(s=0;s<p->nmsg;s++){
    rec.prod=p->id;
    rec.seq=s;
    rc=mqenq(gq,&rec,(unsigned)sizeof rec);
    if(rc){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      break;
    }
  }
  return 0;
}
static void *
cons(void *arg)
{
  int rc;
  int spins;
  int stop;
  int bad;
  unsigned n;
  rec_t rec;
  (void)arg;
  spins=0;
  for(;;){
    n=0;
    rc=mqdeq(gq,&rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY){
      pthread_mutex_lock(&glock);
      stop=(gbad || gcount==gtot);
      pthread_mutex_unlock(&glock);
      if(stop)
        break;
      if(++spins>100000000){
        pthread_mutex_lock(&glock);
        gbad=1;
        pthread_mutex_unlock(&glock);
        break;
      }
      continue;
    }
    spins=0;
    bad=0;
    if(rc!=RC_OK || n!=sizeof rec)
      bad=1;
    pthread_mutex_lock(&glock);
    if(bad)
      gbad=1;
    else if(rec.prod<0 || rec.prod>=8)
      gbad=1;
    else if(rec.seq!=glast[rec.prod]+1)
      gbad=1;
    else{
      glast[rec.prod]=rec.seq;
      gcount++;
    }
    bad=gbad;
    pthread_mutex_unlock(&glock);
    if(bad)
      break;
  }
  return 0;
}
static int
shape(void *q,int np,int nc)
{
  pthread_t tp[8];
  pthread_t tc[8];
  parg arg[8];
  time_t t0;
  time_t t1;
  int i;
  int rc;
  int gotp;
  int gotc;
  gbad=0;
  gcount=0;
  gtot=np*NMSG;
  for(i=0;i<np;i++)
    glast[i]=-1;
  gotc=0;
  for(i=0;i<nc;i++){
    rc=pthread_create(&tc[i],0,cons,0);
    if(rc)
      return 1;
    gotc++;
  }
  t0=time(0);
  gotp=0;
  for(i=0;i<np;i++){
    arg[i].id=i;
    arg[i].nmsg=NMSG;
    rc=pthread_create(&tp[i],0,prod,&arg[i]);
    if(rc){
      gbad=1;
      break;
    }
    gotp++;
  }
  for(i=0;i<gotp;i++)
    pthread_join(tp[i],0);
  for(i=0;i<gotc;i++)
    pthread_join(tc[i],0);
  t1=time(0);
  printf("T25 %dP%dC sec %d\n",
         np,nc,(int)(t1-t0));
  fflush(stdout);
  mqshow("T25",q);
  if(gbad || gcount!=gtot)
    return 1;
  return 0;
}
static int
wrap(void *q)
{
  static slowctx ctx;
  void *ep;
  unsigned *seq;
  int rc;
  int i;
  char src[4];
  time_t t;
  ep=(void *)SLOWCB;
  memset(&ctx,0,sizeof ctx);
  rc=mqinit(q,0,64,ep,&ctx,0);
  if(rc!=RC_OK)
    return rc;
  /* QCB_ENQ_SEQ IS BYTE 48. SEEN IS THE NEXT WORD. */
  seq=(unsigned *)((char *)q+48);
  *seq=0xFFFFFFF0u;
  seq[1]=0xFFFFFFF0u;
  for(i=0;i<NWRAP;i++){
    src[0]=(char)i;
    rc=mqenq(q,src,1);
    if(rc!=RC_OK)
      return rc;
  }
  t=time(0);
  while(ctx.sum<NWRAP){
    if(time(0)>t+30)
      return 2;
  }
  rc=mqstop(q);
  if(rc!=RC_OK)
    return rc;
  if(ctx.sum!=NWRAP)
    return 3;
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  static unsigned char raww[1600];
  const char *who;
  void *q;
  int rc;
  who="T25BENCH";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,1024,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  if(shape(q,1,1) || shape(q,2,2) ||
     shape(q,4,4) || shape(q,8,8)){
    mqshow(who,q);
    return mqfail(who,"shape");
  }
  q=mqalign(raww,sizeof raww);
  if(q==0)
    return mqfail(who,"align2");
  rc=wrap(q);
  mqshow(who,q);
  if(rc)
    return mqfailn(who,"wrap",rc);
  return mqpass(who);
}
