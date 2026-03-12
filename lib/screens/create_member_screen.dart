import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/member.dart';

class CreateMemberScreen extends StatefulWidget {
  const CreateMemberScreen({super.key});

  @override
  State<CreateMemberScreen> createState() => _CreateMemberScreenState();
}

class _CreateMemberScreenState extends State<CreateMemberScreen> {
  bool _isSaving = false;
  bool _loadingLocalities = false;
  String? _errorMessage;

  List<Map<String, dynamic>> _localities = [];
  Map<String, dynamic>? _selectedLocality;
  List<Member> _allMembers = [];

  final _memberIdCtrl   = TextEditingController();
  final _nameCtrl       = TextEditingController();
  final _dobCtrl        = TextEditingController();
  final _addressCtrl    = TextEditingController();
  final _phoneCtrl      = TextEditingController();
  final _emailCtrl      = TextEditingController();
  final _idNumberCtrl   = TextEditingController();
  final _idTypeCtrl     = TextEditingController();
  final _notesCtrl      = TextEditingController();
  bool _status = true;

  @override
  void initState() {
    super.initState();
    _loadLocalities();
  }

  @override
  void dispose() {
    _memberIdCtrl.dispose();
    _nameCtrl.dispose();
    _dobCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _idNumberCtrl.dispose();
    _idTypeCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocalities() async {
    setState(() => _loadingLocalities = true);
    try {
      final api = context.read<AuthProvider>().apiService!;
      final localities = await api.listLocalities();
      setState(() {
        _localities = localities;
        _loadingLocalities = false;
      });
    } catch (_) {
      setState(() => _loadingLocalities = false);
    }
    // Load members separately so a failure here doesn't block the form
    try {
      final api = context.read<AuthProvider>().apiService!;
      final members = await api.listMembers();
      setState(() => _allMembers = members);
    } catch (_) {}
  }

  void _onLocalitySelected(Map<String, dynamic>? locality) {
    setState(() {
      _selectedLocality = locality;
      if (locality != null) {
        final code = (locality['code'] as String).padLeft(3, '0');
        final prefix = 'MK$code';
        // Global sequence = total number of members + 1
        final nextSeq = _allMembers.length + 1;
        debugPrint('allMembers: ${_allMembers.length}, nextSeq: $nextSeq');
        _memberIdCtrl.text = _buildMemberId(code, nextSeq);
      }
    });
  }

  String _buildMemberId(String code, int seq) {
    return 'MK${code.padLeft(3, '0')}${seq.toString().padLeft(8, '0')}';
  }

  Future<void> _submit() async {
    final memberId = _memberIdCtrl.text.trim();
    final name     = _nameCtrl.text.trim();

    if (memberId.isEmpty || name.isEmpty) {
      setState(() => _errorMessage = 'Member ID and Full Name are required.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final newMember = Member(
        memberId:             memberId,
        companyId:            'KAFA-001',
        fullName:             name,
        dateOfBirth:          _dobCtrl.text.trim(),
        address:              _addressCtrl.text.trim(),
        phone:                _phoneCtrl.text.trim(),
        email:                _emailCtrl.text.trim(),
        identificationNumber: _idNumberCtrl.text.trim(),
        identificationType:   _idTypeCtrl.text.trim(),
        status:               _status,
        notes:                _notesCtrl.text.trim(),
        locality:             _selectedLocality,
      );

      final api = context.read<AuthProvider>().apiService!;
      final created = await api.createMember(newMember);

      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Member')),
      body: _isSaving
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFFC8A96E)),
                  SizedBox(height: 16),
                  Text('Creating member...'),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_errorMessage != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_errorMessage!,
                                style: TextStyle(
                                    color: Colors.red.shade700,
                                    fontSize: 13)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () =>
                                setState(() => _errorMessage = null),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),

                  _buildCard(
                    title: 'MEMBER INFO',
                    children: [
                      _buildCommuneDropdown(),
                      const SizedBox(height: 12),
                      _field(_memberIdCtrl, 'Member ID *', Icons.badge,
                          hint: 'e.g. MK08100000001'),
                      const SizedBox(height: 4),
                      Text(
                        'Auto-filled by commune. Edit the last digits for the sequence number.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _buildCard(
                    title: 'PERSONAL INFO',
                    children: [
                      _field(_nameCtrl, 'Full Name *', Icons.person),
                      const SizedBox(height: 12),
                      _field(_dobCtrl, 'Date of Birth', Icons.cake,
                          hint: 'YYYY-MM-DD'),
                      const SizedBox(height: 12),
                      _field(_addressCtrl, 'Address', Icons.home,
                          maxLines: 2),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _buildCard(
                    title: 'CONTACT',
                    children: [
                      _field(_phoneCtrl, 'Phone', Icons.phone,
                          type: TextInputType.phone),
                      const SizedBox(height: 12),
                      _field(_emailCtrl, 'Email', Icons.email,
                          type: TextInputType.emailAddress),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _buildCard(
                    title: 'IDENTIFICATION',
                    children: [
                      _field(_idNumberCtrl, 'ID Number', Icons.credit_card),
                      const SizedBox(height: 12),
                      _field(_idTypeCtrl, 'ID Type', Icons.article),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _buildCard(
                    title: 'STATUS',
                    children: [
                      SwitchListTile(
                        value: _status,
                        onChanged: (v) => setState(() => _status = v),
                        title: Text(_status ? 'Active' : 'Inactive'),
                        activeColor: const Color(0xFF1A5C2A),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _buildCard(
                    title: 'NOTES',
                    children: [
                      _field(_notesCtrl, 'Notes', Icons.notes, maxLines: 3),
                    ],
                  ),

                  const SizedBox(height: 80),
                ],
              ),
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, -2))
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.grey),
                ),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.grey)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _submit,
                icon: const Icon(Icons.person_add),
                label: const Text('Create Member',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF1A5C2A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
      {required String title, required List<Widget> children}) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                title,
                style: const TextStyle(
                  color: Color(0xFFC8A96E),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildCommuneDropdown() {
    if (_loadingLocalities) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFC8A96E))),
            SizedBox(width: 8),
            Text('Loading communes...', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    return Autocomplete<Map<String, dynamic>>(
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) return _localities;
        return _localities.where((l) => (l['commune'] as String)
            .toLowerCase()
            .contains(textEditingValue.text.toLowerCase()));
      },
      displayStringForOption: (option) => option['commune'] as String,
      onSelected: _onLocalitySelected,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Commune',
            prefixIcon: Icon(Icons.location_on),
            suffixIcon: Icon(Icons.arrow_drop_down),
            isDense: true,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxHeight: 200, maxWidth: 400),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on,
                        size: 16, color: Color(0xFF1A5C2A)),
                    title: Text(option['commune'] as String),
                    subtitle: Text('Code: ${option['code']}',
                        style: const TextStyle(fontSize: 11)),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    String? hint,
    int maxLines = 1,
    TextInputType? type,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        isDense: true,
      ),
    );
  }
}