#include "qcall.h"
/* CALLBACK AND USER ECB ON THE SAME QUEUE.     */
/* FOUR ENQUEUES. THE ECB IS POSTED. THE        */
/* CALLBACK SEES THE SEQUENCE GAP.              */
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
  unsigned uecb;
  char src[4];
  who="T15BOTH";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  memset(&blk,0,sizeof blk);
  uecb=0;
  ep=(void *)TSTCB;
  rc=mqinit(q,0,8,ep,&blk,&uecb);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  for(i=0;i<4;i++){
    src[0]=(char)('A'+i);
    rc=mqenq(q,src,1);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"enq",rc);
    }
  }
  mqwait((unsigned *)&blk.ecb);
  if(blk.calls<1 || blk.pending<1){
    mqshow(who,q);
    return mqfailn(who,"calls",blk.calls);
  }
  if((uecb&0x40000000u)==0){
    mqshow(who,q);
    return mqfail(who,"ecb");
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  mqshow(who,q);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.enq_ok!=4 || st.post_usr!=4)
    return mqfail(who,"post");
  if(st.cb_calls<1)
    return mqfail(who,"cb");
  rc=mqstop(q);
  if(rc!=RC_OK)
    return mqfailn(who,"stop",rc);
  return mqpass(who);
}
