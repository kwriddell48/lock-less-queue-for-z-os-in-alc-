#include "qcall.h"
/* ENQUEUE A BATCH, THEN DEQUEUE IN THE SAME ORDER.  */
#define NMSG 24
typedef struct {
  int seq;
  char tag[8];
} item;
int
main(void)
{
  static unsigned char raw[1600];
  const char *who;
  void *q;
  int rc;
  int i;
  unsigned n;
  item in;
  item out;
  who="T02FIFO";
  mqwhen(who,"START");
  q=mqalign(raw,sizeof raw);
  if(q==0)
    return mqfail(who,"align");
  rc=mqinit(q,0,32,0,0,0);
  if(rc!=RC_OK)
    return mqfailn(who,"init",rc);
  for(i=0;i<NMSG;i++){
    in.seq=i;
    memcpy(in.tag,"T02FIFO",7);
    in.tag[7]='X';
    rc=mqenq(q,&in,(unsigned)sizeof in);
    if(rc!=RC_OK){
      mqshow(who,q);
      return mqfailn(who,"enq",rc);
    }
  }
  for(i=0;i<NMSG;i++){
    memset(&out,0,sizeof out);
    n=0;
    rc=mqdeq(q,&out,(unsigned)sizeof out,&n);
    if(rc!=RC_OK || n!=sizeof out){
      mqshow(who,q);
      return mqfailn(who,"deq",rc);
    }
    if(out.seq!=i || memcmp(out.tag,"T02FIFO",7)!=0){
      mqshow(who,q);
      return mqfailn(who,"order",i);
    }
    if(out.tag[7]!='X'){
      mqshow(who,q);
      return mqfail(who,"tag");
    }
  }
  rc=mqdeq(q,&out,(unsigned)sizeof out,&n);
  if(rc!=RC_EMPTY){
    mqshow(who,q);
    return mqfailn(who,"tail",rc);
  }
  mqshow(who,q);
  return mqpass(who);
}
