#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include <time.h>
#include "qcall.h"
/* SHORT THREADS FILL TLS SLOTS AND EXIT.       */
/* EACH ENQUEUES 4 AND DEQUEUES 2, SO NODES     */
/* STAY IN THAT TCB SLOT. AFTER THE STAMP AGE,  */
/* A NEW WAVE REUSES THE SLOTS AND WE DRAIN.    */
#define WAVE 8
#define FIRST 16
#define SECOND 8
#define PER 4
#define TOTAL ((FIRST+SECOND)*WAVE*PER)
typedef struct {
  int id;
} rec_t;
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gnext;
static unsigned char gseen[TOTAL];
static int
ticket(void)
{
  int id;
  pthread_mutex_lock(&glock);
  id=gnext++;
  pthread_mutex_unlock(&glock);
  return id;
}
static void
mark(int id)
{
  pthread_mutex_lock(&glock);
  if(id<0 || id>=TOTAL || gseen[id])
    gbad=1;
  else
    gseen[id]=1;
  pthread_mutex_unlock(&glock);
}
static void *
one(void *arg)
{
  int i;
  int rc;
  int id;
  unsigned n;
  rec_t rec;
  (void)arg;
  for(i=0;i<PER;i++){
    id=ticket();
    rec.id=id;
    rc=mqenq(gq,&rec,(unsigned)sizeof rec);
    if(rc!=RC_OK){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      return 0;
    }
  }
  for(i=0;i<PER/2;i++){
    n=0;
    rc=mqdeq(gq,&rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY)
      continue;
    if(rc!=RC_OK || n!=sizeof rec){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      return 0;
    }
    mark(rec.id);
  }
  return 0;
}
static int
batch(int nwave)
{
  pthread_t th[WAVE];
  int w;
  int i;
  int rc;
  int got;
  for(w=0;w<nwave;w++){
    got=0;
    for(i=0;i<WAVE;i++){
      rc=pthread_create(&th[i],0,one,0);
      if(rc){
        pthread_mutex_lock(&glock);
        gbad=1;
        pthread_mutex_unlock(&glock);
        break;
      }
      got++;
    }
    for(i=0;i<got;i++)
      pthread_join(th[i],0);
    if(gbad)
      return 1;
  }
  return 0;
}
static void
pause2(void)
{
  time_t t;
  t=time(0);
  while(time(0)<t+2)
    ;
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  int rc;
  int i;
  int left;
  unsigned n;
  rec_t rec;
  who="T19CHURN";
  mqwhen(who,"START");
  gbad=0;
  gnext=0;
  memset(gseen,0,sizeof gseen);
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,64,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  if(batch(FIRST)){
    mqshow(who,q);
    return mqfail(who,"wave1");
  }
  pause2();
  if(batch(SECOND)){
    mqshow(who,q);
    return mqfail(who,"wave2");
  }
  left=0;
  for(;;){
    n=0;
    rc=mqdeq(q,&rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY)
      break;
    if(rc!=RC_OK || n!=sizeof rec){
      mqshow(who,q);
      return mqfailn(who,"drain",rc);
    }
    mark(rec.id);
    left++;
  }
  if(gbad){
    mqshow(who,q);
    return mqfail(who,"data");
  }
  for(i=0;i<TOTAL;i++){
    if(gseen[i]!=1){
      mqshow(who,q);
      return mqfailn(who,"miss",i);
    }
  }
  mqshow(who,q);
  if(left<1)
    return mqfail(who,"empty");
  return mqpass(who);
}
