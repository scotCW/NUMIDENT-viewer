# NUMIDENT forms for Gramps

Form definitions for the Gramps **Form** addon, one per NUMIDENT record set:

| Form id | Title | Event type it creates | Sections |
|---|---|---|---|
| `NUMSS5` | NUMIDENT SS-5 Application | Social Security Application | Number Holder, Father, Mother |
| `NUMCLM` | NUMIDENT Claim Record | Social Security Claim | Number Holder, Father, Mother |
| `NUMDEATH` | NUMIDENT Death Record | Social Security Death Record | Deceased |

Fields follow NARA's record layouts in [`../docs/nara/`](../docs/nara/).

## Install

Copy `custom.xml` into the Form addon's folder and restart Gramps (forms are
read only at startup):

```bash
cp custom.xml ~/Library/Application\ Support/gramps/gramps60/plugins/Form/custom.xml
```

If the Form gramplet's New and Edit buttons disappear, the file has an error;
see `gramps60.log` in the Gramps user folder.

## Use

1. Create one source per record set, e.g. *NUMIDENT SS-5 Applications (NARA RG 47)*.
2. On the source's **Attributes** tab add an attribute named `Form` whose value
   is the form id: `NUMSS5`, `NUMCLM` or `NUMDEATH`.
3. Open the person, go to the **Form** gramplet, click **New**, and pick the source.
4. Fill in the citation's Volume/Page with where the record is: the form
   pre-fills `Reference No.: , File: `, e.g.
   `Reference No.: 65008336075, File: NUMCLM01_PU.txt @ 2500` (the viewer
   shows the file and position for each result).
5. Set **Date** to the date the record was posted to the NUMIDENT (the
   viewer's "SS-5 …" event date, or the cycle date). Leave **Place** empty
   unless the record names a town: for a claim, you can use the field
   office's town from Field Office Address.
6. Fill in the fields and select the people for the Father and Mother sections.

In the form editor, Source and Reference belong to the citation; Date and
Place belong to the event the form creates.

The citation says *where* the record is; the form fields say *what* it records.
The SSN goes only in the person's Social Security Number field: one person can
have several records under the same SSN, so it doesn't identify a record.

## Entering values

- **Coded fields** (sex, race, entry, form used, evidence, citizenship, signed
  by, claim type, source and proof of death, programs): enter the meaning,
  e.g. `White`, not `1`. The NUMIDENT viewer's person view decodes every code.
  Enter `Unknown` for an unknown code, and leave a field empty when the record
  is blank.
- **Names, places, SSN, ZIP codes, field office code**: exactly as recorded.
- **Dates**: readable, noting unknown parts, e.g. `1974-06 (day not recorded)`.
- **The original codes**: in the viewer, right-click the result, choose
  *Copy raw line*, and paste it into a note on the citation. That keeps the
  complete record as NARA released it.

Code meanings can depend on the date. For example, the SS-5's race choices
were expanded around 1980, so `Other` on an early application can cover groups
with their own code later. The form's Date Posted shows which applied.

Each form makes its own event type rather than a standard one, as the Form
addon recommends: the addon manages every event of a form's type, so using
Death could overwrite existing death events. Add the actual birth or death as
a normal Gramps event citing the same source.

Once you have entered data, don't rename any `_attribute` in `custom.xml`:
Gramps stores values under those exact names.
