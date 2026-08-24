import 'package:flutter/material.dart';
import '../../models/xdata_form_model.dart';

class XdataFormWidget extends StatefulWidget {
  final XdataForm form;
  final void Function(XdataForm submittedForm)? onSubmit;
  final VoidCallback? onCancel;
  final bool readOnly;

  const XdataFormWidget({
    super.key,
    required this.form,
    this.onSubmit,
    this.onCancel,
    this.readOnly = false,
  });

  @override
  State<XdataFormWidget> createState() => _XdataFormWidgetState();
}

class _XdataFormWidgetState extends State<XdataFormWidget> {
  late List<XdataField> _fields;
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _fields = [];
    for (final f in widget.form.fields) {
      _fields.add(f.copyWith());
    }
    for (final field in _fields) {
      _controllers[field.varName] = TextEditingController(text: field.value ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _updateField(String varName, String? value, List<String>? multiValues) {
    setState(() {
      for (int i = 0; i < _fields.length; i++) {
        if (_fields[i].varName == varName) {
          if (_fields[i].type == 'list-multi' || _fields[i].type == 'text-multi') {
            _fields[i] = _fields[i].copyWith(values: multiValues);
          } else {
            _fields[i] = _fields[i].copyWith(value: value);
          }
          break;
        }
      }
    });
  }

  void _submit() {
    final submittedForm = XdataForm(
      title: widget.form.title,
      type: 'submit',
      fields: _fields,
    );
    widget.onSubmit?.call(submittedForm);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.form.title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.form.title!,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        if (widget.form.instructions != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              widget.form.instructions!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final field in _fields)
                  _buildFieldWidget(context, field),
              ],
            ),
          ),
        ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onCancel != null)
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFieldWidget(BuildContext context, XdataField field) {
    final theme = Theme.of(context);
    final isReadOnly = widget.readOnly || field.type == 'fixed';

    Widget fieldWidget;
    switch (field.type) {
      case 'boolean':
        fieldWidget = _buildBooleanField(field, isReadOnly);
        break;
      case 'text-private':
      case 'text-single':
        fieldWidget = _buildTextField(field, isReadOnly, obscureText: field.type == 'text-private');
        break;
      case 'text-multi':
        fieldWidget = _buildTextMultiField(field, isReadOnly);
        break;
      case 'list-single':
        fieldWidget = _buildListSingleField(field, isReadOnly);
        break;
      case 'list-multi':
        fieldWidget = _buildListMultiField(field, isReadOnly);
        break;
      case 'jid-single':
        fieldWidget = _buildTextField(field, isReadOnly, keyboardType: TextInputType.emailAddress);
        break;
      case 'jid-multi':
        fieldWidget = _buildTextMultiField(field, isReadOnly, hintText: 'user@domain.com');
        break;
      default:
        fieldWidget = _buildTextField(field, isReadOnly);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label ?? field.varName,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: field.required ? theme.colorScheme.error : null,
                  ),
                ),
              ),
              if (field.required)
                Text(
                  '*',
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.error),
                ),
            ],
          ),
          if (field.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                field.description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
          fieldWidget,
        ],
      ),
    );
  }

  Widget _buildBooleanField(XdataField field, bool isReadOnly) {
    final currentValue = field.value == '1' || field.value == 'true';
    return Row(
      children: [
        Switch(
          value: currentValue,
          onChanged: isReadOnly
              ? null
              : (v) {
                  _updateField(field.varName, v ? '1' : '0', null);
                },
        ),
        Text(currentValue ? 'Yes' : 'No'),
      ],
    );
  }

  Widget _buildTextField(XdataField field, bool isReadOnly, {bool obscureText = false, TextInputType? keyboardType}) {
    return TextField(
      controller: _controllers[field.varName],
      readOnly: isReadOnly,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: (v) => _updateField(field.varName, v, null),
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        isDense: true,
      ),
    );
  }

  Widget _buildTextMultiField(XdataField field, bool isReadOnly, {String? hintText}) {
    String initialText;
    if (field.type == 'list-multi') {
      initialText = field.values.join('\n');
    } else {
      initialText = field.value ?? '';
    }
    if (_controllers[field.varName]?.text != initialText) {
      _controllers[field.varName]?.text = initialText;
    }
    return TextField(
      controller: _controllers[field.varName],
      readOnly: isReadOnly,
      maxLines: 4,
      keyboardType: TextInputType.multiline,
      onChanged: (v) {
        if (field.type == 'list-multi') {
          _updateField(field.varName, null, v.split('\n').where((s) => s.isNotEmpty).toList());
        } else {
          _updateField(field.varName, v, null);
        }
      },
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.all(12),
        isDense: true,
      ),
    );
  }

  Widget _buildListSingleField(XdataField field, bool isReadOnly) {
    final currentValue = field.value ?? '';
    final validOptions = field.options.where((o) => o.value == currentValue).toList();
    final selectedValue = validOptions.isNotEmpty ? currentValue : null;

    return DropdownButtonFormField<String>(
      value: selectedValue,
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        isDense: true,
      ),
      isExpanded: true,
      hint: const Text('Select...'),
      items: field.options.map((opt) {
        return DropdownMenuItem<String>(
          value: opt.value,
          child: Text(opt.label ?? opt.value, overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: isReadOnly
          ? null
          : (v) {
              if (v != null) {
                _updateField(field.varName, v, null);
                _controllers[field.varName]?.text = v;
              }
            },
    );
  }

  Widget _buildListMultiField(XdataField field, bool isReadOnly) {
    final selectedValues = field.values.toSet();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: field.options.map((opt) {
        final isSelected = selectedValues.contains(opt.value);
        return FilterChip(
          label: Text(opt.label ?? opt.value),
          selected: isSelected,
          onSelected: isReadOnly
              ? null
              : (selected) {
                  final newValues = List<String>.from(selectedValues);
                  if (selected) {
                    newValues.add(opt.value);
                  } else {
                    newValues.remove(opt.value);
                  }
                  _updateField(field.varName, null, newValues);
                },
        );
      }).toList(),
    );
  }
}
