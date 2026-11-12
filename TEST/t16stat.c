#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* QSTATS RUNS WHILE TWO PRODUCERS AND TWO      */
/* CONSUMERS MOVE INLINE RECORDS.               */
#define NPROD 2
#define NCONS 2
#define NMSG 40
#define NTOT (NPROD*NMSG)
typedef struct {
  int prod;
  int seq;
} rec_t;
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gcount;
static volatile int gdone;
static int gst;
static int glast[NPROD];
static void *
prod(void *arg)
{
  int id;
  int s;
  int rc;
  rec_t rec;
  id=*(int *)arg;
  for(s=0;s<NMSG;s++){
    rec.prod=id;
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
  unsigned n;
  rec_t rec;
  (void)arg;
  spins=0;
  for(;;){
    n=0;
    rc=mqdeq(gq,&rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY){
      pthread_mutex_lock(&glock);
      stop=(gbad || gcount==NTOT);
      pthread_mutex_unlock(&glock);
      if(stop)
        break;
      if(++spins>10000000){
        pthread_mutex_lock(&glock);
        gbad=1;
        pthread_mutex_unlock(&glock);
        break;
      }
      continue;
    }
    spins=0;
    if(rc!=RC_OK || n!=sizeof rec){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      break;
    }
    pthread_mutex_lock(&glock);
    if(rec.prod<0 || rec.prod>=NPROD)
      gbad=1;
    else if(rec.seq!=glast[rec.prod]+1)
      gbad=1;
    else{
      glast[rec.prod]=rec.seq;
      gcount++;
    }
    pthread_mutex_unlock(&glock);
    if(gbad)
      break;
  }
  return 0;
}
static void *
stats(void *arg)
{
  mqstat st;
  int rc;
  (void)arg;
  while(!gdone){
    memset(&st,0,sizeof st);
    rc=mqstats(gq,&st,(unsigned)sizeof st);
    if(rc!=RC_OK){
      gbad=1;
      break;
    }
    gst++;
  }
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  pthread_t tc[NCONS];
  pthread_t tp[NPROD];
  pthread_t ts;
  int ids[NPROD];
  mqstat st;
  void *q;
  int rc;
  int i;
  int np;
  int nc;
  who="T16STAT";
  mqwhen(who,"START");
  gbad=0;
  gcount=0;
  gdone=0;
  gst=0;
  for(i=0;i<NPROD;i++)
    glast[i]=-1;
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,120,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  rc=pthread_create(&ts,0,stats,0);
  if(rc)
    return mqfailn(who,"statth",rc);
  np=0;
  nc=0;
  for(i=0;i<NCONS;i++){
    rc=pthread_create(&tc[i],0,cons,0);
    if(rc){
      gbad=1;
      break;
    }
    nc++;
  }
  for(i=0;i<NPROD;i++){
    ids[i]=i;
    rc=pthread_create(&tp[i],0,prod,&ids[i]);
    if(rc){
      gbad=1;
      break;
    }
    np++;
  }
  for(i=0;i<np;i++)
    pthread_join(tp[i],0);
  for(i=0;i<nc;i++)
    pthread_join(tc[i],0);
  gdone=1;
  pthread_join(ts,0);
  mqshow(who,q);
  if(gbad)
    return mqfail(who,"data");
  if(gcount!=NTOT)
    return mqfailn(who,"count",gcount);
  if(gst<1)
    return mqfail(who,"nostat");
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.enq_ok!=NTOT || st.deq_ok!=NTOT)
    return mqfail(who,"match");
  return mqpass(who);
}
