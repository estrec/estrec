# ESTREC WRITE OUTFILE='fit.estrec.json' [TITLE='...'] [IDENTIFYING=YES|NO]: write an estrec
# record of the last supported procedure in the Viewer, by re-running its syntax (from the
# Notes table) quietly inside a capture. Used by the Extensions menu dialog.
import estrec_session


def Run(args):
    args = args[list(args.keys())[0]]
    from extension import Template, Syntax, processcmd

    oobj = Syntax([
        Template("OUTFILE", subc="", ktype="literal", var="outfile"),
        Template("TITLE", subc="", ktype="literal", var="title"),
        Template("IDENTIFYING", subc="", ktype="bool", var="identifying"),
    ])
    processcmd(oobj, args, _write)


def _write(outfile, title=None, identifying=False):
    estrec_session.write_last(outfile, title=title, identifying=identifying)
