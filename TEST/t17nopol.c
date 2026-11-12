#include "qcall.h"
/* INITIAL POOL IS ZERO. THE MAIN TASK OBTAINS  */
/* EVERY NODE, THEN DRAINS THE QUEUE.           */
#define NMSG 8
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
  char src[8];
  char dst[8];
  who="T17NOPOL";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  rc=mqinit(q,0,0,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  for(i=0;i<NMSG;i++){
    src[0]=(char)('A'+i);
    rc=mqenq(q,src,1);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"enq",rc);
    }
  }
  for(i=0;i<NMSG;i++){
    memset(dst,0,sizeof dst);
    n=0;
    rc=mqdeq(q,dst,sizeof dst,&n);
    if(rc!=RC_OK || n!=1 || dst[0]!=(char)('A'+i)){
      mqshow(who,q);
      return mqfailn(who,"deq",rc);
    }
  }
  n=0;
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"empty",rc);
  }
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  mqshow(who,q);
  if(rc!=RC_OK)
    return mqfailn(who,"stat",rc);
  if(st.enq_ok!=NMSG || st.deq_ok!=NMSG)
    return mqfail(who,"count");
  if(st.deq_empty<1 || st.depth!=0)
    return mqfail(who,"left");
  return mqpass(who);
}
