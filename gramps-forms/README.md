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

Each form makes its own event type rather than a standard one, as the Form
addon recommends: the addon manages every event of a form's type, so using
Death could overwrite existing death events. Add the actual birth or death as
a normal Gramps event citing the same source.

Once you have entered data, don't rename any `_attribute` in `custom.xml`:
Gramps stores values under those exact names.
