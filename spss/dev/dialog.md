# Building the "Save estimation record" dialog (SPSS 32, Custom Dialog Builder)

The dialog only writes `ESTREC WRITE` syntax; the command does the work.

1. **Extensions > Utilities > Custom Dialog Builder for Extensions.**
2. **Dialog properties** (click the empty canvas):
   - Dialog Name: `ESTREC_WRITE`
   - Title: `Save estimation record`
   - Menu Location: **Extensions** (or File > Export, if you prefer), item `Save estimation record...`
   - Help File: none
3. **Add controls** from the Tools palette:
   - **File Browser**: Identifier `outfile`, Title `Save the record as`, File System Operation
     **Save**, Browser Type **File**, File Filter `estrec records (*.estrec.json)|*.estrec.json`,
     Required **Yes**.
   - **Text control**: Identifier `title`, Title `Title (optional)`.
   - **Check Box**: Identifier `identifying`, Title `Also record the data file's path`,
     Checked/Unchecked syntax `YES` / `NO`, default unchecked.
   - **Static Text** (optional): `Records the last REGRESSION, UNIANOVA, LOGISTIC REGRESSION,
     GENLIN, MIXED or GENLINMIXED in the Viewer by re-running its syntax quietly.`
4. **Syntax template** (Dialog properties > Syntax, or the Syntax button):
   ```
   ESTREC WRITE OUTFILE="%%outfile%%" %%title%% IDENTIFYING=%%identifying%%.
   ```
   For the `title` control set its Syntax to `TITLE="%%ThisValue%%"` so it is left out
   when empty.
5. **Extension properties** (Extension > Properties): Name `ESTREC`, Summary as you like,
   Version `0.1.0`. Under **Required files** add the nine files from the extensions folder:
   ESTREC_BEGIN/END/WRITE `.xml` and `.py`, estrec_session.py, estrec_oxml.py,
   estrec_procedures.py, estrec_record.py.
6. **File > Save** as `estrec_with_dialog.spe`, then **File > Install** to try it.
7. Copy `estrec_with_dialog.spe` to valiant `raw/estrec_test/`. The dialog file in it is added
   to `spss/estrec.spe` by `spss/build_bundle.py`.
