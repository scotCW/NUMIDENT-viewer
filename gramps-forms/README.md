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
4. Put the record's SSN and reference number in the citation's Volume/Page
   (the form pre-fills `SSN: , Reference No.: `), fill in the fields, and
   select the people for the Father and Mother sections.

## Entering values

- **Coded fields** (sex, race, entry, form used, evidence, citizenship, signed
  by, claim type, source and proof of death, programs): enter the meaning,
  e.g. `White`, not `1`. The NUMIDENT viewer's person view decodes every code.
  Enter `Unknown` for an unknown code, and leave a field empty when the record
  is blank.
- **Names, places, SSN, ZIP codes, field office code**: exactly as recorded.
- **Dates**: readable, noting unknown parts, e.g. `1974-06 (day not recorded)`.
- **Data File**: the file and record position the viewer shows,
  e.g. `NUMDEATH01_PU.TXT @ 0`.
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
