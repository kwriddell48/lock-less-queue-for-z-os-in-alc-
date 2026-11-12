#include "qcall.h"
/* STOP THE NOTIFIER, THEN ENQUEUE AGAIN.       */
/* THE NEW RECORD DEQUEUES. THE CALLBACK COUNT  */
/* DOES NOT MOVE. THE STEP MUST NOT ABEND A03.  */
typedef struct {
  volatile int calls;
  volatile int pending;
  volatile unsigned int ecb;
} cbblk;
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  void *ep;
  cbblk blk;
  mqstat st;
  int rc;
  int i;
  int calls;
  unsigned n;
  char src[4];
  char dst[4];
  who="T14STOP";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  memset(&blk,0,sizeof blk);
  ep=(void *)TSTCB;
  rc=mqinit(q,0,8,ep,&blk,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  memcpy(src,"AB",2);
  rc=mqenq(q,src,2);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq",rc);
  }
  memcpy(src,"CD",2);
  rc=mqenq(q,src,2);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq2",rc);
  }
  mqwait((unsigned *)&blk.ecb);
  if(blk.calls<1){
    mqshow(who,q);
    return mqfailn(who,"calls",blk.calls);
  }
  calls=blk.calls;
  rc=mqstop(q);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stop",rc);
  }
  memcpy(src,"ZZ",2);
  rc=mqenq(q,src,2);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"after",rc);
  }
  for(i=0;i<2;i++){
    n=0;
    rc=mqdeq(q,dst,sizeof dst,&n);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"deq",rc);
    }
  }
  memset(dst,0,sizeof dst);
  n=0;
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_OK || n!=2 || memcmp(dst,"ZZ",2)!=0){
    mqshow(who,q);
    return mqfail(who,"afterq");
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  mqshow(who,q);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.cb_calls!=calls)
    return mqfailn(who,"cb",st.cb_calls);
  if(st.enq_ok!=3)
    return mqfailn(who,"enqok",st.enq_ok);
  return mqpass(who);
}
