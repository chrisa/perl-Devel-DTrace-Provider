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

STATIC MGVTBL probeargs_vtbl = { 0, 0, 0, 0, 0, 0, 0, 0 };

struct perl_dtrace_provider {
        usdt_provider_t *provider;
        HV *probes;
};

typedef struct perl_dtrace_provider* Devel__DTrace__Provider;
typedef usdt_probedef_t* Devel__DTrace__Probe;

char **
XS_unpack_charPtrPtr (SV *arg)
{
        SV **elem;
        char **ret;
        AV *av;
        I32 i;

        if (!arg || !SvOK (arg) || !SvROK (arg) || (SvTYPE (SvRV (arg)) != SVt_PVAV)) {
                Perl_croak (aTHX_ "array reference expected");
        }

        av = (AV *)SvRV (arg);
        ret = (char **)malloc ((av_len(av) + 1) * sizeof(char *));

        for (i = 0; i <= av_len (av); i++) {
                elem = av_fetch (av, i, 0);
                if (!elem || !*elem) {
                        Perl_croak (aTHX_ "undefined element in arg types array?");
                }
                ret[i] = SvPV_nolen (*elem);
        }

        ret[av_len (av) + 1] = NULL;
        return ret;
}

MODULE = Devel::DTrace::Provider               PACKAGE = Devel::DTrace::Provider

PROTOTYPES: DISABLE

Devel::DTrace::Provider
new(package, name, module)
        char *package
        char *name
        char *module;

        CODE:
        RETVAL = malloc(sizeof(struct perl_dtrace_provider *));
        if (RETVAL == NULL)
                Perl_croak(aTHX_ "Failed to allocate memory for provider: %s", strerror(errno));

        RETVAL->provider = usdt_create_provider(name, module);
        if (RETVAL->provider == NULL)
                Perl_croak(aTHX_ "Failed to allocate memory for provider: %s", strerror(errno));

        RETVAL->probes = newHV();

        OUTPUT:
        RETVAL

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

        CODE:
        types = malloc(USDT_ARG_MAX * sizeof(perl_argtype_t));

        for (i = 0; i < USDT_ARG_MAX; i++) {
                if (perl_types[i] == NULL)
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

        if ((usdt_provider_add_probe(self->provider, RETVAL) < 0))
                Perl_croak(aTHX_ "add probe: %s", usdt_errstr(self->provider));

        ST(0) = sv_newmortal();
        sv_setref_pv(ST(0), "Devel::DTrace::Probe", (void*)RETVAL);
        sv_magicext(SvRV(ST(0)), Nullsv, PERL_MAGIC_ext, &probeargs_vtbl,
                    (const char *) types, 0);

        (void) hv_store(self->probes, name, strlen(name), SvREFCNT_inc((SV *)ST(0)), 0);

void
remove_probe(self, probe)
        Devel::DTrace::Provider self
        Devel::DTrace::Probe probe;

        CODE:
        (void) hv_delete(self->probes, probe->name, strlen(probe->name), G_DISCARD);

        if (usdt_provider_remove_probe(self->provider, probe) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self->provider));


SV *
enable(self)
        Devel::DTrace::Provider self

        CODE:
        if (usdt_provider_enable(self->provider) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self->provider));

        RETVAL = newRV_inc((SV *)self->probes);

        OUTPUT:
        RETVAL

void
disable(self)
        Devel::DTrace::Provider self

        CODE:
        if (usdt_provider_disable(self->provider) < 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self->provider));


SV *
probes(self)
        Devel::DTrace::Provider self

        CODE:
        RETVAL = newRV_inc((SV *)self->probes);

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

        for (mg = SvMAGIC(SvRV(ST(0))); mg; mg = mg->mg_moremagic)
                if (mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == &probeargs_vtbl)
                        types = (perl_argtype_t *)mg->mg_ptr;
        if (types == NULL)
                Perl_croak(aTHX_ "Missing probe magic?");

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
	};

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
