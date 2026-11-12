#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* POOL STARTS EMPTY. 16 PRODUCERS AND 16        */
/* CONSUMERS ALLOCATE NODES AS THEY RUN.        */
#define NPROD 16
#define NCONS 16
#define NMSG 8
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
static int glast[NPROD];
static unsigned char gseen[NPROD][NMSG];
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
    bad=0;
    if(rc!=RC_OK || n!=sizeof rec)
      bad=1;
    pthread_mutex_lock(&glock);
    if(bad)
      gbad=1;
    else if(rec.prod<0 || rec.prod>=NPROD)
      gbad=1;
    else if(rec.seq<0 || rec.seq>=NMSG)
      gbad=1;
    else if(gseen[rec.prod][rec.seq])
      gbad=1;
    else if(rec.seq!=glast[rec.prod]+1)
      gbad=1;
    else{
      gseen[rec.prod][rec.seq]=1;
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
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  pthread_t tc[NCONS];
  pthread_t tp[NPROD];
  int ids[NPROD];
  mqstat st;
  void *q;
  int rc;
  int i;
  int np;
  int nc;
  who="T21COLD";
  mqwhen(who,"START");
  gbad=0;
  gcount=0;
  memset(gseen,0,sizeof gseen);
  for(i=0;i<NPROD;i++)
    glast[i]=-1;
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,0,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  nc=0;
  for(i=0;i<NCONS;i++){
    rc=pthread_create(&tc[i],0,cons,0);
    if(rc){
      gbad=1;
      break;
    }
    nc++;
  }
  np=0;
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
  mqshow(who,q);
  if(gbad)
    return mqfail(who,"data");
  if(gcount!=NTOT)
    return mqfailn(who,"count",gcount);
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.enq_ok!=NTOT || st.deq_ok!=NTOT)
    return mqfail(who,"ops");
  if(st.depth!=0)
    return mqfail(who,"left");
  return mqpass(who);
}
