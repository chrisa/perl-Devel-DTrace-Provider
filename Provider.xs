#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <usdt.h>

typedef usdt_provider_t* Devel__DTrace__Provider;
typedef usdt_probedef_t* Devel__DTrace__Probe;

char **
XS_unpack_charPtrPtr (SV *arg)
{
        char **ret;
        AV *av;
        I32 i;

        if (!arg || !SvOK (arg) || !SvROK (arg) || (SvTYPE (SvRV (arg)) != SVt_PVAV)) {
                Perl_croak (aTHX_ "array reference expected");
        }

        av = (AV *)SvRV (arg);
        ret = (char **)malloc ((av_len(av) + 1) * sizeof(char *));

        for (i = 0; i <= av_len (av); i++) {
                SV **elem = av_fetch (av, i, 0);
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
        RETVAL = usdt_create_provider(name, module);
        if (RETVAL == NULL)
                Perl_croak(aTHX_ "Failed to allocate memory for provider: %s", strerror(errno));

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
        const char *types[USDT_ARG_MAX];

        CODE:
        for (i = 0; i < USDT_ARG_MAX; i++) {
                if (perl_types[i] == NULL)
                        break;
                if (strcmp("integer", perl_types[i]) == 0) {
                        types[i] = "int";
                        argc++;
                } else if (strcmp("string", perl_types[i]) == 0) {
                        types[i] = "char *";
                        argc++;
                } else {
                        types[i] = NULL;
                }
        }
        if ((RETVAL = usdt_create_probe(function, name, argc, types)) == NULL)
                Perl_croak(aTHX_ "create probe failed");

        if ((usdt_provider_add_probe(self, RETVAL) < 0))
                Perl_croak(aTHX_ "add probe: %s", usdt_errstr(self));

        OUTPUT:
        RETVAL

int
enable(self)
        Devel::DTrace::Provider self

        CODE:
        if (usdt_provider_enable(self) != 0)
                Perl_croak(aTHX_ "%s", usdt_errstr(self));

        RETVAL = 1; /* XXX */

        OUTPUT:
        RETVAL

MODULE = Devel::DTrace::Provider               PACKAGE = Devel::DTrace::Probe

PROTOTYPES: DISABLE

int
fire(self, ...)
Devel::DTrace::Probe self

        PREINIT:
	void *argv[USDT_ARG_MAX];
        size_t argc = 0;

	CODE:
	argc = items - 1;
	if (argc != self->argc)
	  Perl_croak(aTHX_ "Probe takes %d arguments, %d provided", self->argc, argc);

  	for (size_t i = 0; i < self->argc; i++) {
	  switch (self->types[i]) {
	  case USDT_ARGTYPE_STRING:
	    if (SvPOK(ST(i + 1)))
	      argv[i] = (void *)(SvPV_nolen(ST(i + 1)));
	    else
	      Perl_croak(aTHX_ "Argument type mismatch: %d should be string", i);
	    break;
	  case USDT_ARGTYPE_INTEGER:
	    if (SvIOK(ST(i + 1)))
	      argv[i] = (void *)(SvIV(ST(i + 1)));
	    else
	      Perl_croak(aTHX_ "Argument type mismatch: %d should be integer", i);
	    break;
	  }
	}
        usdt_fire_probe(self->probe, argc, argv);

        RETVAL = 1; /* XXX */

        OUTPUT:
        RETVAL
