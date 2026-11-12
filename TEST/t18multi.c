#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* FOUR QUEUES RUN AT THE SAME TIME.            */
/* EACH HAS TWO PRODUCERS AND TWO CONSUMERS.    */
/* A RECORD CARRIES ITS QUEUE ID. INLINE ONLY.  */
/* EACH POOL COVERS THAT QUEUE'S RECORDS.       */
#define NQ 4
#define NPROD 2
#define NCONS 2
#define NMSG 20
#define NTOT (NPROD*NMSG)
#define NPOOL (NTOT+NPROD*4)
typedef struct {
  int qid;
  int prod;
  int seq;
} rec_t;
typedef struct {
  int q;
  int id;
} targ;
typedef struct {
  void *q;
  pthread_mutex_t lock;
  int bad;
  int count;
  int last[NPROD];
  unsigned char seen[NPROD][NMSG];
} qst;
static qst qs[NQ];
static targ pa[NQ][NPROD];
static targ ca[NQ][NCONS];
static void
failall(void)
{
  int i;
  for(i=0;i<NQ;i++){
    pthread_mutex_lock(&qs[i].lock);
    qs[i].bad=1;
    pthread_mutex_unlock(&qs[i].lock);
  }
}
static void *
prod(void *arg)
{
  targ *t;
  int s;
  int rc;
  rec_t rec;
  t=(targ *)arg;
  for(s=0;s<NMSG;s++){
    rec.qid=t->q;
    rec.prod=t->id;
    rec.seq=s;
    rc=mqenq(qs[t->q].q,&rec,
             (unsigned)sizeof rec);
    if(rc){
      failall();
      break;
    }
  }
  return 0;
}
static void *
cons(void *arg)
{
  targ *t;
  qst *s;
  int rc;
  int spins;
  int stop;
  int bad;
  unsigned n;
  rec_t rec;
  t=(targ *)arg;
  s=&qs[t->q];
  spins=0;
  for(;;){
    n=0;
    rc=mqdeq(s->q,&rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY){
      pthread_mutex_lock(&s->lock);
      stop=(s->bad || s->count==NTOT);
      pthread_mutex_unlock(&s->lock);
      if(stop)
        break;
      if(++spins>10000000){
        failall();
        break;
      }
      continue;
    }
    spins=0;
    bad=0;
    if(rc!=RC_OK || n!=sizeof rec)
      bad=1;
    else if(rec.qid!=t->q)
      bad=1;
    pthread_mutex_lock(&s->lock);
    if(bad)
      s->bad=1;
    else if(rec.prod<0 || rec.prod>=NPROD)
      s->bad=1;
    else if(rec.seq<0 || rec.seq>=NMSG)
      s->bad=1;
    else if(s->seen[rec.prod][rec.seq])
      s->bad=1;
    else if(rec.seq!=s->last[rec.prod]+1)
      s->bad=1;
    else{
      s->seen[rec.prod][rec.seq]=1;
      s->last[rec.prod]=rec.seq;
      s->count++;
    }
    bad=s->bad;
    pthread_mutex_unlock(&s->lock);
    if(bad)
      break;
  }
  return 0;
}
int
main(void)
{
  static unsigned char raw[NQ][1600];
  static pthread_t tp[NQ][NPROD];
  static pthread_t tc[NQ][NCONS];
  const char *who;
  mqstat st;
  char tag[8];
  int rc;
  int i;
  int k;
  int p;
  int s;
  int np[NQ];
  int nc[NQ];
  int bad;
  who="T18MULTI";
  mqwhen(who,"START");
  bad=0;
  for(i=0;i<NQ;i++){
    pthread_mutex_init(&qs[i].lock,0);
    qs[i].bad=0;
    qs[i].count=0;
    memset(qs[i].seen,0,sizeof qs[i].seen);
    for(k=0;k<NPROD;k++)
      qs[i].last[k]=-1;
    qs[i].q=mqalign(raw[i],sizeof raw[i]);
    if(qs[i].q==0)
      return mqfail(who,"align");
    rc=mqinit(qs[i].q,0,NPOOL,0,0,0);
    if(rc!=RC_OK)
      return mqfailn(who,"init",rc);
    np[i]=0;
    nc[i]=0;
  }
  for(i=0;i<NQ;i++){
    for(k=0;k<NCONS;k++){
      ca[i][k].q=i;
      ca[i][k].id=k;
      rc=pthread_create(&tc[i][k],0,cons,
                         &ca[i][k]);
      if(rc){
        failall();
        bad=1;
        break;
      }
      nc[i]++;
    }
    if(bad)
      break;
  }
  if(!bad){
    for(i=0;i<NQ;i++){
      for(k=0;k<NPROD;k++){
        pa[i][k].q=i;
        pa[i][k].id=k;
        rc=pthread_create(&tp[i][k],0,prod,
                           &pa[i][k]);
        if(rc){
          failall();
          bad=1;
          break;
        }
        np[i]++;
      }
      if(bad)
        break;
    }
  }
  for(i=0;i<NQ;i++){
    for(k=0;k<np[i];k++)
      pthread_join(tp[i][k],0);
    for(k=0;k<nc[i];k++)
      pthread_join(tc[i][k],0);
  }
  for(i=0;i<NQ;i++){
    tag[0]='Q';
    tag[1]=(char)('0'+i);
    tag[2]=0;
    mqshow(tag,qs[i].q);
    if(qs[i].bad || qs[i].count!=NTOT)
      bad=1;
    for(p=0;p<NPROD && !bad;p++){
      for(s=0;s<NMSG;s++){
        if(qs[i].seen[p][s]!=1)
          bad=1;
      }
    }
    memset(&st,0,sizeof st);
    rc=mqstats(qs[i].q,&st,(unsigned)sizeof st);
    if(rc!=RC_OK || st.enq_ok!=NTOT)
      bad=1;
    if(st.deq_ok!=NTOT || st.depth!=0)
      bad=1;
  }
  if(bad)
    return mqfail(who,"data");
  return mqpass(who);
}
