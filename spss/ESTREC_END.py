# ESTREC END OUTFILE='fit.estrec.json' [TITLE='...'] [IDENTIFYING=YES|NO]: write one estrec
# record per supported procedure run since ESTREC BEGIN (see estrec_session.py).
import estrec_session


def Run(args):
    args = args[list(args.keys())[0]]
    from extension import Template, Syntax, processcmd

    oobj = Syntax([
        Template("OUTFILE", subc="", ktype="literal", var="outfile"),
        Template("TITLE", subc="", ktype="literal", var="title"),
        Template("IDENTIFYING", subc="", ktype="bool", var="identifying"),
    ])
    processcmd(oobj, args, _end)


def _end(outfile, title=None, identifying=False):
    estrec_session.end(outfile, title=title, identifying=identifying)
