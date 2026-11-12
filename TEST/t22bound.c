#include <stdlib.h>
#include "qcall.h"
/* TIER EDGES, A NULL LENGTH POINTER, A ZERO     */
/* BUFFER, AND LENGTHS PAST THE UNSIGNED MAX.    */
#define BIG 16777215u
static unsigned char *
block(unsigned n)
{
  return (unsigned char *)malloc(n);
}
static void
paint(unsigned char *p,unsigned n,unsigned tag)
{
  unsigned i;
  if(n>=4)
    *(unsigned *)p=tag;
  for(i=4;i<n;i++)
    p[i]=(unsigned char)(tag+i);
}
static int
same(unsigned char *p,unsigned n,unsigned tag)
{
  unsigned i;
  if(n>=4 && *(unsigned *)p!=tag)
    return 1;
  for(i=4;i<n;i++){
    if(p[i]!=(unsigned char)(tag+i))
      return 1;
  }
  return 0;
}
static int
roundtrip(void *q,unsigned n)
{
  unsigned char *src;
  unsigned char *dst;
  unsigned out;
  int rc;
  src=block(n);
  dst=block(n);
  if(src==0 || dst==0){
    free(src);
    free(dst);
    return -1;
  }
  paint(src,n,n);
  rc=mqenq(q,src,n);
  if(rc!=RC_OK){
    free(src);
    free(dst);
    return rc;
  }
  out=0;
  rc=mqdeq(q,dst,n,&out);
  if(rc!=RC_OK || out!=n || same(dst,n,n)){
    free(src);
    free(dst);
    return rc==RC_OK?1:rc;
  }
  free(src);
  free(dst);
  return 0;
}
int
main(void)
{
  static unsigned char raw[1600];
  static unsigned edge[]={
    1024,1025,2048,2049,65536,65537
  };
  const char *who;
  void *q;
  unsigned char tiny[16];
  unsigned char *big;
  unsigned n;
  unsigned out;
  int rc;
  int i;
  who="T22BOUND";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  rc=mqinit(q,0,16,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  for(i=0;i<6;i++){
    rc=roundtrip(q,edge[i]);
    if(rc){
      mqshow(who,q);
      return mqfailn(who,"edge",rc);
    }
  }
  rc=roundtrip(q,1048576u);
  if(rc){
    mqshow(who,q);
    return mqfailn(who,"mb",rc);
  }
  rc=roundtrip(q,1048577u);
  if(rc){
    mqshow(who,q);
    return mqfailn(who,"mb1",rc);
  }
  paint(tiny,4,4);
  rc=mqenq(q,tiny,0x80000000u);
  if(rc!=RC_ALLOC){
    mqshow(who,q);
    return mqfailn(who,"neg",rc);
  }
  rc=mqenq(q,tiny,16777216u);
  if(rc!=RC_ALLOC){
    mqshow(who,q);
    return mqfailn(who,"over",rc);
  }
  big=block(BIG);
  if(big==0){
    mqshow(who,q);
    return mqfail(who,"nomem");
  }
  paint(big,BIG,BIG);
  rc=mqenq(q,big,BIG);
  if(rc!=RC_OK){
    free(big);
    mqshow(who,q);
    return mqfailn(who,"max",rc);
  }
  out=0;
  rc=mqdeq(q,big,64,&out);
  if(rc!=RC_TRUNC || out!=BIG){
    free(big);
    mqshow(who,q);
    return mqfailn(who,"maxq",rc);
  }
  free(big);
  paint(tiny,8,8);
  rc=mqenq(q,tiny,8);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq",rc);
  }
  rc=mqdeq(q,tiny,8,0);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"null",rc);
  }
  paint(tiny,8,9);
  rc=mqenq(q,tiny,8);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq2",rc);
  }
  out=0;
  rc=mqdeq(q,tiny,0,&out);
  if(rc!=RC_TRUNC || out!=8){
    mqshow(who,q);
    return mqfailn(who,"zbuf",rc);
  }
  rc=mqenq(q,tiny,0);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"zlen",rc);
  }
  out=99;
  rc=mqdeq(q,tiny,0,&out);
  if(rc!=RC_OK || out!=0){
    mqshow(who,q);
    return mqfailn(who,"zz",rc);
  }
  paint(tiny,4,4);
  rc=mqenq(q,tiny,4);
  if(rc!=RC_OK){
    mqshow(who,q);
    return mqfailn(who,"enq3",rc);
  }
  n=0;
  rc=mqdeq(q,tiny,0x80000000u,&n);
  if(rc!=RC_OK || n!=4){
    mqshow(who,q);
    return mqfailn(who,"huge",rc);
  }
  mqshow(who,q);
  return mqpass(who);
}
