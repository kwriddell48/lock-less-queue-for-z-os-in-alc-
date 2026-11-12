#include "qcall.h"
/* USER ECB IS POSTED ON EACH SUCCESSFUL ENQUEUE.    */
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  mqstat st;
  int rc;
  unsigned ecb;
  char src[4];
  who="T06ECB";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  ecb=0;
  rc=mqinit(q,0,4,0,0,&ecb);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  memcpy(src,"ECB1",4);
  rc=mqenq(q,src,4);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq1",rc);
  }
  mqwait(&ecb);
  memcpy(src,"ECB2",4);
  rc=mqenq(q,src,4);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq2",rc);
  }
  mqwait(&ecb);
  memset(&st,0,sizeof st);
  rc=mqstats(q,&st,(unsigned)sizeof st);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"stat",rc);
  }
  if(st.enq_ok!=2 || st.post_usr!=2){
    mqshow(who,q);
    return mqfail(who,"post");
  }
  if(st.post_int!=0){
    mqshow(who,q);
    return mqfail(who,"noint");
  }
  mqshow(who,q);
  return mqpass(who);
}
