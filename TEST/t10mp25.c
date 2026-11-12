#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* 25 PRODUCERS AND 25 CONSUMERS.               */
/* LENGTHS RUN FROM 16 THROUGH 1024, INLINE.    */
/* EACH BYTE DEPENDS ON PRODUCER, SEQUENCE,     */
/* AND OFFSET. ORDER STAYS PER PRODUCER.        */
/* THE POOL HOLDS EVERY RECORD, SO A WORKER     */
/* DOES NOT GETMAIN A NODE.                     */
#define NPROD 25
#define NCONS 25
#define NMSG 20
#define NTOT (NPROD*NMSG)
#define NPOOL (NTOT+NPROD*4)
typedef struct {
  int prod;
  int seq;
  unsigned int sum;
  unsigned int len;
  unsigned char body[1008];
} rec_t;
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gcount;
static int glast[NPROD];
static unsigned char gseen[NPROD][NMSG];
static unsigned
paylen(int id,int s)
{
  static unsigned lens[8]={
    16,32,64,128,256,512,768,1024
  };
  return lens[(id+s)&7];
}
static unsigned char
paybyte(int id,int s,int i)
{
  return (unsigned char)(id*17+s*5+i*3);
}
static void *
prod(void *arg)
{
  int id;
  int s;
  int i;
  int rc;
  unsigned n;
  rec_t rec;
  id=*(int *)arg;
  for(s=0;s<NMSG;s++){
    n=paylen(id,s);
    rec.prod=id;
    rec.seq=s;
    rec.len=n;
    rec.sum=(unsigned)id*1000u
            +(unsigned)s+n;
    for(i=0;i<(int)(n-16u);i++)
      rec.body[i]=paybyte(id,s,i);
    rc=mqenq(gq,&rec,n);
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
  int i;
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
    if(rc!=RC_OK || n!=rec.len || n<16)
      bad=1;
    else if(rec.sum!=(unsigned)rec.prod*1000u
            +(unsigned)rec.seq+rec.len)
      bad=1;
    else if(n-16u>sizeof rec.body)
      bad=1;
    else{
      for(i=0;i<(int)(n-16u);i++){
        if(rec.body[i]!=
           paybyte(rec.prod,rec.seq,i)){
          bad=1;
          break;
        }
      }
    }
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
    else {
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
  int p;
  int s;
  int nc;
  int np;
  who="T10MP25";
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
  rc=mqinit(q,0,NPOOL,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  nc=0;
  for(i=0;i<NCONS;i++){
    rc=pthread_create(&tc[i],0,cons,0);
    if(rc){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      break;
    }
    nc++;
  }
  np=0;
  if(nc==NCONS){
    for(i=0;i<NPROD;i++){
      ids[i]=i;
      rc=pthread_create(&tp[i],0,prod,&ids[i]);
      if(rc){
        pthread_mutex_lock(&glock);
        gbad=1;
        pthread_mutex_unlock(&glock);
        break;
      }
      np++;
    }
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
  for(p=0;p<NPROD;p++){
    for(s=0;s<NMSG;s++){
      if(gseen[p][s]!=1){
        mqshow(who,q);
        return mqfail(who,"missing");
      }
    }
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.enq_ok!=NTOT || st.deq_ok!=NTOT)
    return mqfail(who,"stat");
  if(st.depth!=0 || st.pay_lo!=0)
    return mqfail(who,"left");
  if(st.pay_hi!=0)
    return mqfail(who,"left");
  return mqpass(who);
}
