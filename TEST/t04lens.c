#include "qcall.h"
#include <stdlib.h>
/* ONE RECORD AT A TIME ON THE MAIN TASK.            */
/* 0..1024 INLINE, THEN 2K 4K 8K 16K 32K 64K,        */
/* THEN ONE BYTE OVER 64K (IARV64).                  */
int
main(void)
{
  static unsigned char raw[1600];
  static unsigned lens[]={
    0,1,1024,1025,3000,5000,10000,
    20000,40000,65536,65537
  };
  const char *who;
  void *q;
  unsigned char *buf;
  unsigned char *src;
  unsigned char *dst;
  unsigned n;
  unsigned out;
  int rc;
  int i;
  int k;
  int nlen;
  who="T04LENS";
  mqwhen(who,"START");
  nlen=(int)(sizeof lens/sizeof lens[0]);
  buf=(unsigned char *)malloc(65537U*2U);
  if(buf==0)
    return mqfail(who,"nomem");
  src=buf;
  dst=buf+65537;
  q=mqalign(raw,sizeof raw);
  if(q==0){
    free(buf);
    return mqfail(who,"align");
  }
  rc=mqinit(q,0,8,0,0,0);
  if(rc!=RC_OK){
    free(buf);
    return mqfailn(who,"init",rc);
  }
  for(k=0;k<nlen;k++){
    n=lens[k];
    for(i=0;i<(int)n;i++)
      src[i]=(unsigned char)(i+n);
    rc=mqenq(q,src,n);
    if(rc!=RC_OK){
      mqshow(who,q);
      printf("%s FAIL enq %u rc %d\n",
             who,n,rc);
      free(buf);
      mqwhen(who,"END");
      return 1;
    }
    memset(dst,0xFF,n>0?n:1);
    out=0;
    rc=mqdeq(q,dst,n,&out);
    if(rc!=RC_OK || out!=n){
      mqshow(who,q);
      printf("%s FAIL deq %u rc %d\n",
             who,n,rc);
      free(buf);
      mqwhen(who,"END");
      return 1;
    }
    if(n>0 && memcmp(src,dst,n)!=0){
      mqshow(who,q);
      printf("%s FAIL bytes %u\n",who,n);
      free(buf);
      mqwhen(who,"END");
      return 1;
    }
  }
  mqshow(who,q);
  free(buf);
  return mqpass(who);
}
