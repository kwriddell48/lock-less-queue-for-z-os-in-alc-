#define _OPEN_THREADS 1
#ifdef __MVS__
#pragma runopts(POSIX(ON))
#endif
#include <pthread.h>
#include "qcall.h"
/* ONE PRODUCER AND ONE CONSUMER. INLINE RECORDS.    */
/* INITPOOL COVERS THE NODES SO THE WORKER DOES NOT  */
/* GETMAIN A CELL OF ITS OWN.                        */
#define NMSG 40
static void *gq;
static volatile int gbad;
static void *
prod(void *arg)
{
  int s;
  int rc;
  int rec[2];
  (void)arg;
  for(s=0;s<NMSG;s++){
    rec[0]=s;
    rec[1]=0x31415926;
    rc=mqenq(gq,rec,(unsigned)sizeof rec);
    if(rc){
      gbad=1;
      break;
    }
  }
  return 0;
}
static void *
cons(void *arg)
{
  int rc;
  int expect;
  int spins;
  unsigned n;
  int rec[2];
  (void)arg;
  expect=0;
  spins=0;
  while(expect<NMSG){
    n=0;
    rc=mqdeq(gq,rec,(unsigned)sizeof rec,&n);
    if(rc==RC_EMPTY){
      if(gbad)
        break;
      if(++spins>10000000){
        gbad=1;
        break;
      }
      continue;
    }
    spins=0;
    if(rc!=RC_OK || n!=sizeof rec){
      gbad=1;
      break;
    }
    if(rec[0]!=expect || rec[1]!=0x31415926){
      gbad=1;
      break;
    }
    expect++;
  }
  if(expect!=NMSG)
    gbad=1;
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  pthread_t tp;
  pthread_t tc;
  void *q;
  int rc;
  who="T08PAIR";
  mqwhen(who,"START");
  gbad=0;
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  gq=q;
  rc=mqinit(q,0,64,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  rc=pthread_create(&tc,0,cons,0);
  if(rc)
    return mqfailn(who,"cons",rc);
  rc=pthread_create(&tp,0,prod,0);
  if(rc){
    gbad=1;
    pthread_join(tc,0);
    mqshow(who,q);
    return mqfailn(who,"prod",rc);
  }
  pthread_join(tp,0);
  pthread_join(tc,0);
  mqshow(who,q);
  if(gbad)
    return mqfail(who,"data");
  return mqpass(who);
}
