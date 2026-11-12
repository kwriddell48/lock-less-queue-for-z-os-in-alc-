#include "qcall.h"
/* ALIGNED QINIT, ONE RECORD, EMPTY DEQUEUE.          */
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  void *bad;
  int rc;
  int ver;
  unsigned n;
  char src[8];
  char dst[8];
  who="T01INIT";
  mqwhen(who,"START");
  rc=mqinit(0,0,0,0,0,0);
  if(rc!=RC_ALIGN)
    return mqfailn(who,"null",rc);
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  bad=(char *)q+4;
  rc=mqinit(bad,0,0,0,0,0);
  if(rc!=RC_ALIGN)
    return mqfailn(who,"mis",rc);
  rc=mqinit(q,0,4,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  if(memcmp(q,"MPMCQCB ",8)!=0){
    mqshow(who,q);
    return mqfail(who,"eye");
  }
  ver=*(int *)((char *)q+24);
  if(ver!=1){
    mqshow(who,q);
    return mqfailn(who,"ver",ver);
  }
  n=99;
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"empty",rc);
  }
  memcpy(src,"HELLO",5);
  rc=mqenq(q,src,5);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq",rc);
  }
  memset(dst,0,sizeof dst);
  n=0;
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_OK || n!=5){
    mqshow(who,q);
    return mqfailn(who,"deq",rc);
  }
  if(memcmp(dst,"HELLO",5)!=0){
    mqshow(who,q);
    return mqfail(who,"data");
  }
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"empty2",rc);
  }
  mqshow(who,q);
  return mqpass(who);
}
