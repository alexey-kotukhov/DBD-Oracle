/*
   $Id: dbdimp.h,v 1.12 1996/10/15 02:19:14 timbo Exp $

   Copyright (c) 1994,1995  Tim Bunce

   You may distribute under the terms of either the GNU General Public
   License or the Artistic License, as specified in the Perl README file.

*/

/* these are (almost) random values ! */
#define MAX_COLS 1025


#ifndef HDA_SIZE
#define HDA_SIZE 512
#endif

typedef struct imp_fbh_st imp_fbh_t;

struct imp_drh_st {
    dbih_drc_t com;		/* MUST be first element in structure	*/
};

/* Define dbh implementor data structure */
struct imp_dbh_st {
    dbih_dbc_t com;		/* MUST be first element in structure	*/

    Lda_Def lda;
    ub1     hda[HDA_SIZE];
};


/* Define sth implementor data structure */
struct imp_sth_st {
    dbih_stc_t com;		/* MUST be first element in structure	*/

    Cda_Def *cda;	/* currently just points to cdabuf below */
    Cda_Def cdabuf;

    /* Input Details	*/
    char      *statement;	/* sql (see sth_scan)		*/
    HV        *all_params_hv;	/* all params, keyed by name	*/
    AV        *out_params_av;	/* quick access to inout params	*/

    /* Select Column Output Details	*/
    int        done_desc;   /* have we described this sth yet ?	*/
    imp_fbh_t *fbh;	    /* array of imp_fbh_t structs	*/
    char      *fbh_cbuf;    /* memory for all field names       */
    sb4   long_buflen;      /* length for long/longraw (if >0)	*/
    bool  long_trunc_ok;    /* is truncating a long an error	*/

	/* (In/)Out Parameter Details */
    bool  has_inout_params;
};
#define IMP_STH_EXECUTING	0x0001


struct imp_fbh_st { 	/* field buffer EXPERIMENTAL */
    imp_sth_t *imp_sth;	/* 'parent' statement */

    /* Oracle's description of the field	*/
    sb4  dbsize;
    sb2  dbtype;
    sb1  *cbuf;		/* ptr to name of select-list item */
    sb4  cbufl;		/* length of select-list item name */
    sb4  dsize;		/* max display size if field is a char */
    sb2  prec;
    sb2  scale;
    sb2  nullok;

    /* Our storage space for the field data as it's fetched	*/
    sb2  indp;		/* null/trunc indicator variable	*/
    sword ftype;	/* external datatype we wish to get	*/
    ub1  *buf;		/* data buffer (points to sv data)	*/
    ub2  bufl;		/* length of data buffer		*/
    ub2  rlen;		/* length of returned data		*/
    ub2  rcode;		/* field level error status		*/

    SV	*sv;
};


typedef struct phs_st phs_t;    /* scalar placeholder   */

struct phs_st {	/* scalar placeholder EXPERIMENTAL	*/
    SV	*sv;		/* the scalar holding the value		*/
    sword ftype;	/* external OCI field type		*/
    sb2 indp;		/* null indicator			*/

    /* fields for inout params */
    bool is_inout;
    char *progv;
    ub2 alen;
    ub2 arcode;
    int alen_incnull;	/* 0 or 1 if alen should include null	*/

    char name[1];	/* struct is malloc'd bigger as needed	*/
};


void	ora_error _((SV *h, Lda_Def *lda, int rc, char *what));
void	fbh_dump _((imp_fbh_t *fbh, int i));

void	dbd_init _((dbistate_t *dbistate));
void	dbd_preparse _((imp_sth_t *imp_sth, char *statement));
int 	dbd_describe _((SV *h, imp_sth_t *imp_sth));
int 	dbd_st_blob_read _((SV *sth, int field, long offset, long len,
			SV *destrv, long destoffset));

/* end */
