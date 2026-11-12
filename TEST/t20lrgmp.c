#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include <stdlib.h>
#include "qcall.h"
/* EIGHT PRODUCERS AND EIGHT CONSUMERS.         */
/* SIZES COVER INLINE, EVERY SLAB, AND IARV64.  */
/* EVERY BYTE IS CHECKED. PAYLOAD BYTES END 0.  */
#define NPROD 8
#define NCONS 8
#define NSZ 9
#define NTOT (NPROD*NSZ)
#define MAXB 2097152
static unsigned szs[NSZ]={
  512,2048,4096,8192,16384,
  32768,65536,65537,2097152
};
static void *gq;
static pthread_mutex_t glock=
  PTHREAD_MUTEX_INITIALIZER;
static int gbad;
static int gcount;
static unsigned char gseen[NPROD][NSZ];
static void
fill(unsigned char *p,unsigned n,
     int prod,int seq)
{
  unsigned i;
  *(unsigned *)p=n;
  *(unsigned *)(p+4)=(unsigned)prod;
  *(unsigned *)(p+8)=(unsigned)seq;
  for(i=12;i<n;i++)
    p[i]=(unsigned char)(prod+seq+i);
}
static int
check(unsigned char *p,unsigned n)
{
  unsigned i;
  unsigned want;
  int prod;
  int seq;
  if(n<12)
    return 1;
  want=*(unsigned *)p;
  prod=(int)*(unsigned *)(p+4);
  seq=(int)*(unsigned *)(p+8);
  if(want!=n || prod<0 || prod>=NPROD)
    return 1;
  if(seq<0 || seq>=NSZ || szs[seq]!=n)
    return 1;
  for(i=12;i<n;i++){
    if(p[i]!=(unsigned char)(prod+seq+i))
      return 1;
  }
  return 0;
}
static void *
prod(void *arg)
{
  int id;
  int s;
  int rc;
  unsigned char *buf;
  id=*(int *)arg;
  buf=(unsigned char *)malloc(MAXB);
  if(buf==0){
    pthread_mutex_lock(&glock);
    gbad=1;
    pthread_mutex_unlock(&glock);
    return 0;
  }
  for(s=0;s<NSZ;s++){
    fill(buf,szs[s],id,s);
    rc=mqenq(gq,buf,szs[s]);
    if(rc!=RC_OK){
      pthread_mutex_lock(&glock);
      gbad=1;
      pthread_mutex_unlock(&glock);
      break;
    }
  }
  free(buf);
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
  unsigned char *buf;
  (void)arg;
  buf=(unsigned char *)malloc(MAXB);
  if(buf==0){
    pthread_mutex_lock(&glock);
    gbad=1;
    pthread_mutex_unlock(&glock);
    return 0;
  }
  spins=0;
  for(;;){
    n=0;
    rc=mqdeq(gq,buf,MAXB,&n);
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
    bad=check(buf,n);
    if(rc!=RC_OK)
      bad=1;
    pthread_mutex_lock(&glock);
    if(bad)
      gbad=1;
    else if(gseen[*(unsigned *)(buf+4)]
                  [*(unsigned *)(buf+8)])
      gbad=1;
    else{
      gseen[*(unsigned *)(buf+4)]
           [*(unsigned *)(buf+8)]=1;
      gcount++;
    }
    bad=gbad;
    pthread_mutex_unlock(&glock);
    if(bad)
      break;
  }
  free(buf);
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
  int np;
  int nc;
  who="T20LRGMP";
  mqwhen(who,"START");
  gbad=0;
  gcount=0;
  memset(gseen,0,sizeof gseen);
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,128,0,0,0);
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
  for(p=0;p<NPROD;p++){
    for(s=0;s<NSZ;s++){
      if(gseen[p][s]!=1)
        return mqfail(who,"missing");
    }
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.pay_hi!=0 || st.pay_lo!=0)
    return mqfail(who,"pay");
  if(st.enq_ok!=NTOT || st.deq_ok!=NTOT)
    return mqfail(who,"ops");
  return mqpass(who);
}
