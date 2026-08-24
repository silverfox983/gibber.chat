import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class XdataForm {
  final String? title;
  final List<XdataField> fields;
  final String type;
  final String? instructions;

  XdataForm({
    this.title,
    required this.fields,
    required this.type,
    this.instructions,
  });

  static XdataForm? parse(xmpp.XmppElement? xElement) {
    if (xElement == null) return null;
    final xmlns = xElement.getAttribute('xmlns')?.value;
    if (xmlns != 'jabber:x:data') return null;

    final type = xElement.getAttribute('type')?.value ?? 'form';
    String? title;
    String? instructions;
    final fields = <XdataField>[];

    for (var child in xElement.children) {
      if (child is xmpp.XmppElement) {
        switch (child.name) {
          case 'title':
            title = child.textValue;
            break;
          case 'instructions':
            instructions = child.textValue;
            break;
          case 'field':
            final field = XdataField.parse(child);
            if (field != null) fields.add(field);
            break;
          case 'reported':
            break;
          case 'item':
            break;
        }
      }
    }

    return XdataForm(title: title, fields: fields, type: type, instructions: instructions);
  }

  xmpp.XmppElement toSubmitElement() {
    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'submit'));
    for (var field in fields) {
      if (field.type == 'hidden') {
        x.addChild(field.toSubmitChild());
      }
    }
    for (var field in fields) {
      if (field.type != 'hidden' && field.isModified) {
        x.addChild(field.toSubmitChild());
      }
    }
    return x;
  }

  xmpp.XmppElement toCancelElement() {
    final x = xmpp.XmppElement();
    x.name = 'x';
    x.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    x.addAttribute(xmpp.XmppAttribute('type', 'cancel'));
    return x;
  }
}

class XdataField {
  final String varName;
  final String type;
  final String? label;
  final String? description;
  final String? value;
  final List<String> values;
  final List<XdataOption> options;
  final bool required;
  final bool isModified;

  XdataField({
    required this.varName,
    required this.type,
    this.label,
    this.description,
    this.value,
    this.values = const [],
    this.options = const [],
    this.required = false,
    this.isModified = false,
  });

  XdataField copyWith({
    String? value,
    List<String>? values,
    bool? isModified,
  }) {
    return XdataField(
      varName: varName,
      type: type,
      label: label,
      description: description,
      value: value ?? this.value,
      values: values ?? this.values,
      options: options,
      required: required,
      isModified: isModified ?? true,
    );
  }

  static XdataField? parse(xmpp.XmppElement fieldEl) {
    final varName = fieldEl.getAttribute('var')?.value;
    if (varName == null) return null;

    final type = fieldEl.getAttribute('type')?.value ?? 'text-single';
    final label = fieldEl.getAttribute('label')?.value;
    String? value;
    final values = <String>[];
    final options = <XdataOption>[];
    String? description;
    var required = false;

    for (var child in fieldEl.children) {
      if (child is xmpp.XmppElement) {
        switch (child.name) {
          case 'value':
            final v = child.textValue;
            if (v != null && v.isNotEmpty) {
              if (type == 'list-multi' || type == 'text-multi') {
                values.add(v);
              } else {
                value ??= v;
              }
            }
            break;
          case 'desc':
            description = child.textValue;
            break;
          case 'required':
            required = true;
            break;
          case 'option':
            final optLabel = child.getAttribute('label')?.value;
            final optValue = child.getChild('value')?.textValue;
            if (optValue != null) {
              options.add(XdataOption(label: optLabel, value: optValue));
            }
            break;
        }
      }
    }

    return XdataField(
      varName: varName,
      type: type,
      label: label,
      description: description,
      value: value,
      values: values,
      options: options,
      required: required,
      isModified: false,
    );
  }

  xmpp.XmppElement toSubmitChild() {
    final field = xmpp.XmppElement();
    field.name = 'field';
    field.addAttribute(xmpp.XmppAttribute('var', varName));

    if (type == 'list-multi' || type == 'text-multi') {
      for (var v in values) {
        final valEl = xmpp.XmppElement();
        valEl.name = 'value';
        valEl.textValue = v;
        field.addChild(valEl);
      }
    } else if (value != null) {
      final valEl = xmpp.XmppElement();
      valEl.name = 'value';
      valEl.textValue = value;
      field.addChild(valEl);
    }

    return field;
  }
}

class XdataOption {
  final String? label;
  final String value;

  XdataOption({this.label, required this.value});
}
