# Intelligent Document Processing - IDP

Welcome to the wiki of Intelligent Document Processing, the home of intelligent automations for digitized documents.
Once you digitize documents, what do you plan to do with the recognized data?

**IDP offers extraction, compliancy check and intelligent mapping, all in one pack.**

## Documentation

All documentation — component references, the IDP mapping engine, configuration guide, backlog and worked examples — lives in the **[project wiki](https://github.com/smelgin/jsonlwc/wiki)**.

## Repository layout

```
force-app/idp/main/      IDP: fileJsonReview, jsonForm, jsonFormDemo,
                         fileJsonReviewMappingDemo, the Idp* mapping engine
                         classes, the IDP_* custom metadata types and the
                         pdfjs static resource
force-app/idp/examples/  Runnable IDP demonstrations — one folder each, with
                         their own mapping sets, fields, data and documents
```

Deploy with `sf project deploy start --source-dir force-app/idp/main`. The package
directory stops at `force-app/idp/main`, so the examples are never deployed unless you
name one explicitly — see the [examples index](https://github.com/smelgin/jsonlwc/wiki/Examples) in the wiki.
