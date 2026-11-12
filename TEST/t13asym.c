#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* EIGHT PRODUCERS AND ONE CONSUMER, THEN THE   */
/* REVERSE. SAME QUEUE. INLINE RECORDS.         */
#define NPROD 8
#define NMSG 16
#define NTOT (NPROD*NMSG)
typedef struct {
  int id;
  int nmsg;
} parg;
typedef struct {
  int prod;
  int seq;
} rec_t;
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gcount;
static int gtot;
static int glast[NPROD];
static unsigned char gseen[NPROD][NMSG];
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
static void
reset(void)
{
  int i;
  gbad=0;
  gcount=0;
  memset(gseen,0,sizeof gseen);
  for(i=0;i<NPROD;i++)
    glast[i]=-1;
}
static int
run(int np,int nc,int nmsg)
{
  pthread_t tc[NPROD];
  pthread_t tp[NPROD];
  parg arg[NPROD];
  int i;
  int rc;
  int gotp;
  int gotc;
  reset();
  gtot=np*nmsg;
  gotc=0;
  for(i=0;i<nc;i++){
    rc=pthread_create(&tc[i],0,cons,0);
    if(rc){
      gbad=1;
      break;
    }
    gotc++;
  }
  gotp=0;
  if(gotc==nc){
    for(i=0;i<np;i++){
      arg[i].id=i;
      arg[i].nmsg=nmsg;
      rc=pthread_create(&tp[i],0,prod,&arg[i]);
      if(rc){
        gbad=1;
        break;
      }
      gotp++;
    }
  }
  for(i=0;i<gotp;i++)
    pthread_join(tp[i],0);
  for(i=0;i<gotc;i++)
    pthread_join(tc[i],0);
  if(gbad || gcount!=gtot)
    return 1;
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  mqstat st;
  void *q;
  int rc;
  who="T13ASYM";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,200,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  if(run(8,1,NMSG)){
    mqshow(who,q);
    return mqfail(who,"wide");
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK || st.depth_max<1){
    mqshow(who,q);
    return mqfail(who,"depth");
  }
  if(run(1,8,NMSG)){
    mqshow(who,q);
    return mqfail(who,"deep");
  }
  mqshow(who,q);
  return mqpass(who);
}
