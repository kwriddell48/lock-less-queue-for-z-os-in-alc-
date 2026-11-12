#include "qcall.h"
/* ZERO-LENGTH RECORD, THEN A TRUNCATED COPY-OUT.    */
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  int rc;
  int i;
  unsigned n;
  unsigned char src[40];
  unsigned char dst[40];
  who="T03TRUNC";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  rc=mqinit(q,0,4,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  rc=mqenq(q,src,0);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"zlen",rc);
  }
  n=7;
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_OK || n!=0){
    mqshow(who,q);
    return mqfailn(who,"zdeq",rc);
  }
  for(i=0;i<40;i++)
    src[i]=(unsigned char)(i+1);
  rc=mqenq(q,src,40);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq",rc);
  }
  memset(dst,0xFF,sizeof dst);
  n=0;
  rc=mqdeq(q,dst,10,&n);
  if(rc!=RC_TRUNC || n!=40){
    mqshow(who,q);
    return mqfailn(who,"trunc",rc);
  }
  if(memcmp(dst,src,10)!=0){
    mqshow(who,q);
    return mqfail(who,"prefix");
  }
  rc=mqdeq(q,dst,sizeof dst,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"gone",rc);
  }
  mqshow(who,q);
  return mqpass(who);
}
