#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include <stdlib.h>
#include "qcall.h"
/* MAIN ENQUEUES 1025, SLABS, AND ONE IARV64.   */
/* FOUR CONSUMERS DEQUEUE. MAIN OBTAINS THE     */
/* PAYLOAD AND IS STILL ALIVE WHEN IT IS FREED. */
#define NCONS 4
#define NMSG 8
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gcount;
static unsigned char gseen[NMSG];
static unsigned lens[NMSG]={
  1025,2048,4096,8192,
  16384,32768,65536,65537
};
static void *
cons(void *arg)
{
  int rc;
  int spins;
  int stop;
  int bad;
  unsigned n;
  unsigned idx;
  unsigned i;
  unsigned char *dst;
  (void)arg;
  dst=(unsigned char *)malloc(65537);
  if(dst==0){
    pthread_mutex_lock(&glock);
    gbad=1;
    pthread_mutex_unlock(&glock);
    return 0;
  }
  spins=0;
  for(;;){
    n=0;
    rc=mqdeq(gq,dst,65537,&n);
    if(rc==RC_EMPTY){
      pthread_mutex_lock(&glock);
      stop=(gbad || gcount==NMSG);
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
    idx=0;
    if(rc!=RC_OK || n<4)
      bad=1;
    else{
      idx=*(unsigned *)dst;
      if(idx>=NMSG || n!=lens[idx])
        bad=1;
    }
    if(!bad){
      for(i=4;i<n;i++){
        if(dst[i]!=(unsigned char)(idx+i)){
          bad=1;
          break;
        }
      }
    }
    pthread_mutex_lock(&glock);
    if(bad || gseen[idx])
      gbad=1;
    else{
      gseen[idx]=1;
      gcount++;
    }
    bad=gbad;
    pthread_mutex_unlock(&glock);
    if(bad)
      break;
  }
  free(dst);
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  pthread_t tc[NCONS];
  unsigned char *src;
  void *q;
  int rc;
  int i;
  int k;
  int nc;
  unsigned n;
  who="T11LARGE";
  mqwhen(who,"START");
  gbad=0;
  gcount=0;
  memset(gseen,0,sizeof gseen);
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,16,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  src=(unsigned char *)malloc(65537);
  if(src==0){
    mqshow(who,q);
    return mqfail(who,"nomem");
  }
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
  if(nc==NCONS){
    for(i=0;i<NMSG;i++){
      n=lens[i];
      *(unsigned *)src=(unsigned)i;
      for(k=4;k<(int)n;k++)
        src[k]=(unsigned char)(i+k);
      rc=mqenq(gq,src,n);
      if(rc!=RC_OK){
        pthread_mutex_lock(&glock);
        gbad=1;
        pthread_mutex_unlock(&glock);
        break;
      }
    }
  }
  for(i=0;i<nc;i++)
    pthread_join(tc[i],0);
  free(src);
  mqshow(who,q);
  if(gbad)
    return mqfail(who,"data");
  if(gcount!=NMSG)
    return mqfailn(who,"count",gcount);
  return mqpass(who);
}
