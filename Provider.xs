#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <usdt.h>

typedef enum {
        none = 0,
        integer,
        string
} perl_argtype_t;

STATIC MGVTBL probe_vtbl = { 0, 0, 0, 0, 0, 0, 0, 0 };
STATIC MGVTBL provider_vtbl = { 0, 0, 0, 0, 0, 0, 0, 0 };

typedef usdt_provider_t* Devel__DTrace__Provider;
typedef usdt_probedef_t* Devel__DTrace__Probe;

/* Used by the INPUT typemap for char**.
 * Will convert a Perl AV* (containing strings) to a C char**.
 */
static char **
XS_unpack_charPtrPtr(SV* rv )
{
	AV *av;
	SV **ssv;
	char **s;
	int avlen;
	int x;

	if( SvROK( rv ) && (SvTYPE(SvRV(rv)) == SVt_PVAV) )
		av = (AV*)SvRV(rv);
	else {
		warn("XS_unpack_charPtrPtr: rv was not an AV ref");
		return( (char**)NULL );
	}

	/* is it empty? */
	avlen = av_len(av);
	if( avlen < 0 ){
		warn("XS_unpack_charPtrPtr: array was empty");
		return( (char**)NULL );
	}

	/* av_len+2 == number of strings, plus 1 for an end-of-array sentinel.
	 */
	s = (char **)safemalloc( sizeof(char*) * (avlen + 2) );
	if( s == NULL ){
		warn("XS_unpack_charPtrPtr: unable to malloc char**");
		return( (char**)NULL );
	}
	for( x = 0; x <= avlen; ++x ){
		ssv = av_fetch( av, x, 0 );
		if( ssv != NULL ){
			if( SvPOK( *ssv ) ){
				s[x] = (char *)safemalloc( SvCUR(*ssv) + 1 );
				if( s[x] == NULL )
					warn("XS_unpack_charPtrPtr: unable to malloc char*");
				else
					strcpy( s[x], SvPV( *ssv, PL_na ) );
			}
			else
				warn("XS_unpack_charPtrPtr: array elem %d was not a string.", x );
		}
		else
			s[x] = (char*)NULL;
	}
	s[x] = (char*)NULL; /* sentinel */
	return( s );
}

static void
XS_release_charPtrPtr(char **s)
{
	char **c;
	for( c = s; *c != NULL; ++c )
		safefree( *c );
	safefree( s );
}

static MAGIC *
load_magic(SV *obj, const MGVTBL *vtbl)
{
        MAGIC *mg;

        for (mg = SvMAGIC(obj); mg; mg = mg->mg_moremagic)
                if (mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == vtbl)
                        return mg;

        Perl_croak(aTHX_ "Missing magic?");
        return NULL;
}

MODULE = Devel::DTrace::Provider               PACKAGE = Devel::DTrace::Provider

PROTOTYPES: DISABLE

Devel::DTrace::Provider
new(package, name, module)
        char *package
        char *name
        char *module;

        INIT:
        SV *probes;

        CODE:
        RETVAL = usdt_create_provider(name, module);
        if (RETVAL == NULL)
                Perl_croak(aTHX_ "Failed to allocate memory for provider: %s",
                           strerror(errno));

        ST(0) = sv_newmortal();
        sv_setref_pv(ST(0), "Devel::DTrace::Provider", (void*)RETVAL);

        probes = (SV *)newHV();
        sv_magicext(SvRV(ST(0)), probes, PERL_MAGIC_ext,&provider_vtbl,
                    NULL, 0);

Devel::DTrace::Probe
add_probe(self, name, function, perl_types)
        Devel::DTrace::Provider self
        char *name
        char *function
        char **perl_types;

        INIT:
        int i;
        int argc = 0;
        const char *dtrace_types[USDT_ARG_MAX];
        perl_argtype_t *types;
        MAGIC *mg;
        HV *probes;

        CODE:
        mg = load_magic(SvRV(ST(0)), &provider_vtbl);
        probes = (HV *)mg->mg_obj;

        types = malloc(USDT_ARG_MAX * sizeof(perl_argtype_t));

        for (i = 0; i < USDT_ARG_MAX; i++) {
                if (perl_types == NULL || perl_types[i] == NULL)
                        break;

                if (strncmp("integer", perl_types[i], 7) == 0) {
                        dtrace_types[i] = "int";
                        types[i] = integer;
                        argc++;
                }
                else if (strncmp("string", perl_types[i], 6) == 0) {
                        dtrace_types[i] = "char *";
                        types[i] = string;
                        argc++;
                }
                else {
                        dtrace_types[i] = NULL;
                        types[i] = none;
                }
        }
        free(perl_types);

        RETVAL = usdt_create_probe(function, name, argc, dtrace_types);
        if (RETVAL == NULL)
                Perl_croak(aTHX_ "create probe failed");

        if ((usdt_provider_add_probe(self, RETVAL) < 0))
                Perl_croak(aTHX_ "add probe: %s", usdt_errstr(self));

        ST(0) = sv_newmortal();
        sv_setref_pv(ST(0), "Devel::DTrace::Probe", (void*)RETVAL);
        sv_magicext(SvRV(ST(0)), Nullsv, PERL_MAGIC_ext, &probe_vtbl,
                    (const char *) types, 0);

        (void) hv_store(probes, name, strlen(name), SvREFCNT_inc((SV *)ST(0)), 0);

void
remove_probe(self, probe)
        Devel::DTrace::Provider self
        Devel::DTrace::Probe probe;

        INIT:
        MAGIC *mg;
        HV *probes;

        CODE:
        mg = load_magic(SvRV(ST(0)), &provider_vtbl);
        probes = (HV *)mg->mg_obj;

        (void) hv_delete(probes, probe->name, strlen(probe->name), G_DISCARD);

        if (usdt_provider_remove_probe(self, probe) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self));


SV *
enable(self)
        Devel::DTrace::Provider self

        INIT:
        MAGIC *mg;
        HV *probes;

        CODE:
        mg = load_magic(SvRV(ST(0)), &provider_vtbl);
        probes = (HV *)mg->mg_obj;

        if (usdt_provider_enable(self) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self));

        RETVAL = newRV_inc((SV *)probes);

        OUTPUT:
        RETVAL

void
disable(self)
        Devel::DTrace::Provider self

        CODE:
        if (usdt_provider_disable(self) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self));

SV *
probes(self)
        Devel::DTrace::Provider self

        INIT:
        MAGIC *mg;
        HV *probes;

        CODE:
        mg = load_magic(SvRV(ST(0)), &provider_vtbl);
        probes = (HV *)mg->mg_obj;

        RETVAL = newRV_inc((SV *)probes);

        OUTPUT:
        RETVAL

MODULE = Devel::DTrace::Provider               PACKAGE = Devel::DTrace::Probe

PROTOTYPES: DISABLE

int
fire(self, ...)
Devel::DTrace::Probe self

        PREINIT:
	void *argv[USDT_ARG_MAX];
        size_t i, argc = 0;
        MAGIC *mg;
        perl_argtype_t *types = NULL;

	CODE:
	argc = items - 1;
	if (argc != self->argc)
                Perl_croak(aTHX_ "Probe takes %ld arguments, %ld provided",
                           self->argc, argc);

        mg = load_magic(SvRV(ST(0)), &probe_vtbl);
        types = (perl_argtype_t *)mg->mg_ptr;

  	for (i = 0; i < self->argc; i++) {
                switch (types[i]) {
                case none:
                        argv[i] = NULL;
                        break;
                case integer:
                        if (SvIOK(ST(i + 1)))
                                argv[i] = (void *)(SvIV(ST(i + 1)));
                        else
                                Perl_croak(aTHX_ "Argument type mismatch: %ld should be integer", i);
                        break;
                case string:
                        if (SvPOK(ST(i + 1)))
                                argv[i] = (void *)(SvPV_nolen(ST(i + 1)));
                        else
                                Perl_croak(aTHX_ "Argument type mismatch: %ld should be string", i);
                        break;
                }
	}

        usdt_fire_probe(self->probe, argc, argv);

        RETVAL = 1; /* XXX */

        OUTPUT:
        RETVAL

int
is_enabled(self)
Devel::DTrace::Probe self

        CODE:
        RETVAL = usdt_is_enabled(self->probe);

        OUTPUT:
        RETVAL
