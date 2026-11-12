#include "qcall.h"
/* SINGLE THREAD. COUNTS SHOULD MATCH THE CALLS.     */
#define NMSG 10
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  mqstat st;
  int rc;
  int i;
  unsigned n;
  char rec[16];
  char dst[16];
  who="T05STAT";
  mqwhen(who,"START");
  if(sizeof(mqstat)!=80)
    return mqfail(who,"layout");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  rc=mqinit(q,0,16,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  memset(rec,0x5A,sizeof rec);
  for(i=0;i<NMSG;i++){
    rec[0]=(char)i;
    rc=mqenq(q,rec,(unsigned)sizeof rec);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"enq",rc);
    }
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stat1",rc);
  }
  if(st.version!=1 || st.size!=80){
    mqshow(who,q);
    return mqfail(who,"hdr");
  }
  if(st.enq_ok!=NMSG || st.depth!=NMSG){
    mqshow(who,q);
    return mqfail(who,"depth");
  }
  if(st.depth_max!=NMSG){
    mqshow(who,q);
    return mqfail(who,"max");
  }
  if(st.pay_hi!=0 || st.pay_lo!=NMSG*16){
    mqshow(who,q);
    return mqfail(who,"pay");
  }
  if(st.enq_retry<st.enq_ok){
    mqshow(who,q);
    return mqfail(who,"retry");
  }
  for(i=0;i<NMSG;i++){
    n=0;
    rc=mqdeq(q,dst,(unsigned)sizeof dst,&n);
    if(rc!=RC_OK || n!=sizeof dst){
      mqshow(who,q);
      return mqfailn(who,"deq",rc);
    }
  }
  n=0;
  rc=mqdeq(q,dst,(unsigned)sizeof dst,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"empty",rc);
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stat2",rc);
  }
  if(st.deq_ok!=NMSG || st.deq_empty!=1){
    mqshow(who,q);
    return mqfail(who,"deqcnt");
  }
  if(st.depth!=0 || st.pay_hi!=0 || st.pay_lo!=0){
    mqshow(who,q);
    return mqfail(who,"zero");
  }
  if(st.deq_retry<st.deq_ok+st.deq_empty){
    mqshow(who,q);
    return mqfail(who,"dretry");
  }
  mqshow(who,q);
  return mqpass(who);
}
