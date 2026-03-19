import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:html' as html;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/member.dart';

class MemberDetailScreen extends StatefulWidget {
  final Member member;
  final List<Member> allMembers;
  const MemberDetailScreen({super.key, required this.member, required this.allMembers});

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  late Member _member;
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isDownloading = false;
  String? _successMessage;
  String? _errorMessage;
  String? _downloadError;

  // Edit controllers
  late TextEditingController _memberIdCtrl;
  late TextEditingController _nameCtrl;
  late TextEditingController _dobCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _idNumberCtrl;
  late TextEditingController _idTypeCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _newPasswordCtrl;
  bool _isSavingPassword = false;
  String? _passwordMessage;
  late bool _editStatus;

  // Locality state
  List<Map<String, dynamic>> _localities = [];
  Map<String, dynamic>? _selectedLocality;
  bool _loadingLocalities = false;
  bool _isLoadingSequence = false;

  @override
  void initState() {
    super.initState();
    _member = widget.member;
    _initControllers();
    _loadLocalities();
  }

  void _initControllers() {
    _memberIdCtrl = TextEditingController(text: _member.memberId);
    _nameCtrl     = TextEditingController(text: _member.fullName);
    _dobCtrl      = TextEditingController(text: _member.dateOfBirth);
    _addressCtrl  = TextEditingController(text: _member.address);
    _phoneCtrl    = TextEditingController(text: _member.phone);
    _emailCtrl    = TextEditingController(text: _member.email);
    _idNumberCtrl = TextEditingController(text: _member.identificationNumber);
    _idTypeCtrl   = TextEditingController(text: _member.identificationType);
    _notesCtrl        = TextEditingController(text: _member.notes);
    _newPasswordCtrl  = TextEditingController();
    _editStatus   = _member.status;
    _selectedLocality = _member.locality;
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
    _newPasswordCtrl.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _isEditing = true;
      _successMessage = null;
      _errorMessage = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _memberIdCtrl.text = _member.memberId;
      _nameCtrl.text     = _member.fullName;
      _dobCtrl.text      = _member.dateOfBirth;
      _addressCtrl.text  = _member.address;
      _phoneCtrl.text    = _member.phone;
      _emailCtrl.text    = _member.email;
      _idNumberCtrl.text = _member.identificationNumber;
      _idTypeCtrl.text   = _member.identificationType;
      _notesCtrl.text    = _member.notes;
      _editStatus        = _member.status;
      _selectedLocality  = _member.locality;
    });
  }

  /// When a locality is selected, update the member ID preview.
  /// - Existing MK members: preserve their sequence, just swap the commune prefix.
  /// - MBR members: fetch server sequence to show what the new ID will be.
  void _onLocalitySelected(Map<String, dynamic>? locality) async {
    setState(() {
      _selectedLocality = locality;
      if (locality == null) return;
      final code = (locality['code'] as String).padLeft(3, '0');
      final existingSeq = _extractSequence(_member.memberId);
      if (existingSeq != null) {
        // Already MK format — just update the commune prefix, keep sequence
        _memberIdCtrl.text = _buildMemberId(code, existingSeq);
      } else {
        // MBR format — show loading while we fetch the next sequence
        _isLoadingSequence = true;
        _memberIdCtrl.text = 'Generating...';
      }
    });

    final locality_ = locality;
    if (locality_ == null) return;
    final existingSeq = _extractSequence(_member.memberId);
    if (existingSeq != null) return; // already handled above synchronously

    try {
      final api  = context.read<AuthProvider>().apiService!;
      final seq  = await api.getCompanySequence();
      final code = (locality_['code'] as String).padLeft(3, '0');
      setState(() {
        _memberIdCtrl.text = _buildMemberId(code, seq + 1);
        _isLoadingSequence = false;
      });
    } catch (_) {
      setState(() { _isLoadingSequence = false; });
    }
  }

  String _buildMemberId(String code, int seq) {
    // Format: MK + 3-digit code + 8-digit zero-padded sequence
    // e.g. MK08100000001
    return 'MK${code.padLeft(3, '0')}${seq.toString().padLeft(8, '0')}';
  }

  int? _extractSequence(String memberId) {
    // MK08100000001 → 1
    if (memberId.length >= 13 && memberId.startsWith('MK')) {
      final seqStr = memberId.substring(5); // after MK + 3-digit code
      return int.tryParse(seqStr);
    }
    return null;
  }

  Future<void> _saveUpdate() async {
    final oldMemberId = _member.memberId;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final updatedMember = _member.copyWith(
        memberId:             _memberIdCtrl.text.trim(),
        fullName:             _nameCtrl.text.trim(),
        dateOfBirth:          _dobCtrl.text.trim(),
        address:              _addressCtrl.text.trim(),
        phone:                _phoneCtrl.text.trim(),
        email:                _emailCtrl.text.trim(),
        identificationNumber: _idNumberCtrl.text.trim(),
        identificationType:   _idTypeCtrl.text.trim(),
        notes:                _notesCtrl.text.trim(),
        status:               _editStatus,
        locality:             _selectedLocality,
      );

      final api = context.read<AuthProvider>().apiService!;
      final result = await api.updateMember(updatedMember, oldMemberId: oldMemberId);

      setState(() {
        _member = result;
        _isEditing = false;
        _isSaving = false;
        _successMessage = 'Member updated successfully.';
        _memberIdCtrl.text = result.memberId;
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _toggleStatus() async {
    final newStatus = !_member.status;
    final action = newStatus ? 'activate' : 'deactivate';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${newStatus ? 'Activate' : 'Deactivate'} Member'),
        content: Text('Are you sure you want to $action ${_member.fullName}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: newStatus ? Colors.green : Colors.red,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(newStatus ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSaving = true);
    try {
      final updated = _member.copyWith(status: newStatus);
      final api = context.read<AuthProvider>().apiService!;
      final result = await api.updateMember(updated);
      setState(() {
        _member = result;
        _isSaving = false;
        _successMessage = 'Member ${newStatus ? 'activated' : 'deactivated'} successfully.';
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to update status: $e';
      });
    }
  }

  Future<void> _downloadCertificate(String type) async {
    final phone = _member.phone;
    if (phone.isEmpty) {
      setState(() => _downloadError = 'No phone number on record.');
      return;
    }
    setState(() {
      _isDownloading = true;
      _downloadError = null;
    });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final links = await api.getCertificateLinks(phone);
      final url = type == 'pdf' ? links['pdf'] : links['jpeg'];
      if (url == null || url.isEmpty) {
        setState(() {
          _isDownloading = false;
          _downloadError = 'Certificate link not available.';
        });
        return;
      }
      if (kIsWeb) html.window.open(url, '_blank');
      setState(() => _isDownloading = false);
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadError = 'Failed to retrieve certificate: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_member);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit Member' : 'Member Details'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_member),
          ),
          actions: [
            if (!_isEditing)
              IconButton(
                icon: Icon(
                  _member.status ? Icons.person_off : Icons.person,
                  color: _member.status
                      ? Colors.red.shade300
                      : Colors.green.shade300,
                ),
                tooltip: _member.status ? 'Deactivate Member' : 'Activate Member',
                onPressed: _isSaving ? null : _toggleStatus,
              ),
          ],
        ),
        body: _isSaving
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFC8A96E)),
                    SizedBox(height: 16),
                    Text('Saving changes...'),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_successMessage != null)
                      _Banner(
                          message: _successMessage!,
                          isError: false,
                          onDismiss: () => setState(() => _successMessage = null)),
                    if (_errorMessage != null)
                      _Banner(
                          message: _errorMessage!,
                          isError: true,
                          onDismiss: () => setState(() => _errorMessage = null)),

                    _buildHeaderCard(),
                    const SizedBox(height: 16),

                    _isEditing ? _buildEditForm() : _buildReadOnlyInfo(),

                    const SizedBox(height: 16),

                    if (_member.certificate != null) _buildCertificateCard(),

                    const SizedBox(height: 80),
                  ],
                ),
              ),
        bottomNavigationBar: _buildBottomBar(),
      ),
    );
  }

  Widget _buildHeaderCard() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFF1A5C2A), Color(0xFF154D23)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: const Color(0xFFC8A96E).withOpacity(0.2),
              child: Text(
                _member.fullName.isNotEmpty
                    ? _member.fullName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    color: Color(0xFFC8A96E),
                    fontSize: 26,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_member.fullName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_member.memberId,
                      style: const TextStyle(
                          color: Color(0xFFC8A96E), fontSize: 13)),
                  if (_member.communeName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        Text(_member.communeName,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _member.status
                    ? Colors.green.withOpacity(0.2)
                    : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _member.status ? 'Active' : 'Inactive',
                style: TextStyle(
                  color:
                      _member.status ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyInfo() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'MEMBER INFO'),
            _InfoRow(icon: Icons.badge, label: 'Member ID', value: _member.memberId),
            _InfoRow(icon: Icons.location_on, label: 'Commune', value: _member.communeName),
            const Divider(height: 24),
            const _SectionHeader(title: 'PERSONAL INFO'),
            _InfoRow(icon: Icons.person, label: 'Full Name', value: _member.fullName),
            _InfoRow(icon: Icons.cake, label: 'Date of Birth', value: _member.dateOfBirth),
            _InfoRow(icon: Icons.home, label: 'Address', value: _member.address),
            const Divider(height: 24),
            const _SectionHeader(title: 'CONTACT'),
            _InfoRow(icon: Icons.phone, label: 'Phone', value: _member.phone),
            _InfoRow(icon: Icons.email, label: 'Email', value: _member.email),
            const Divider(height: 24),
            const _SectionHeader(title: 'IDENTIFICATION'),
            _InfoRow(icon: Icons.credit_card, label: 'ID Number', value: _member.identificationNumber),
            _InfoRow(icon: Icons.article, label: 'ID Type', value: _member.identificationType),
            if (_member.notes.isNotEmpty) ...[
              const Divider(height: 24),
              const _SectionHeader(title: 'NOTES'),
              _InfoRow(icon: Icons.notes, label: 'Notes', value: _member.notes),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditForm() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'MEMBER INFO'),

            // Commune dropdown (searchable)
            _buildCommuneDropdown(),
            const SizedBox(height: 12),

            // Member ID (read-only — server generates from commune + sequence)
            _EditField(
              controller: _memberIdCtrl,
              label: 'Member ID',
              icon: Icons.badge,
              hint: 'Select a commune to generate',
              readOnly: true,
            ),
            const SizedBox(height: 4),
            Text(
              _isLoadingSequence
                  ? 'Fetching next sequence...'
                  : 'Auto-generated by the server when saved.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),

            const Divider(height: 24),
            const _SectionHeader(title: 'PERSONAL INFO'),
            _EditField(controller: _nameCtrl, label: 'Full Name', icon: Icons.person),
            const SizedBox(height: 12),
            _EditField(controller: _dobCtrl, label: 'Date of Birth', icon: Icons.cake,
                hint: 'YYYY-MM-DD'),
            const SizedBox(height: 12),
            _EditField(controller: _addressCtrl, label: 'Address', icon: Icons.home,
                maxLines: 2),

            const Divider(height: 24),
            const _SectionHeader(title: 'CONTACT'),
            _EditField(controller: _phoneCtrl, label: 'Phone', icon: Icons.phone,
                keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _EditField(controller: _emailCtrl, label: 'Email', icon: Icons.email,
                keyboardType: TextInputType.emailAddress),

            const Divider(height: 24),
            const _SectionHeader(title: 'IDENTIFICATION'),
            _EditField(controller: _idNumberCtrl, label: 'ID Number', icon: Icons.credit_card),
            const SizedBox(height: 12),
            _EditField(controller: _idTypeCtrl, label: 'ID Type', icon: Icons.article),

            const Divider(height: 24),
            const _SectionHeader(title: 'STATUS'),
            SwitchListTile(
              value: _editStatus,
              onChanged: (v) => setState(() => _editStatus = v),
              title: Text(_editStatus ? 'Active' : 'Inactive'),
              activeColor: const Color(0xFF1A5C2A),
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: 24),
            const _SectionHeader(title: 'NOTES'),
            _EditField(controller: _notesCtrl, label: 'Notes', icon: Icons.notes,
                maxLines: 3),

            const Divider(height: 24),
            const _SectionHeader(title: 'MEMBER PASSWORD'),
            const SizedBox(height: 4),
            Text(
              'Set or update this member\'s password for the Member Portal.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 10),
            _EditField(
              controller: _newPasswordCtrl,
              label: 'New Password',
              icon: Icons.lock_outline,
              obscureText: true,
            ),
            const SizedBox(height: 10),
            if (_passwordMessage != null)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _passwordMessage!.startsWith('✓')
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _passwordMessage!.startsWith('✓')
                        ? Colors.green.shade200
                        : Colors.red.shade200,
                  ),
                ),
                child: Text(_passwordMessage!,
                    style: TextStyle(
                        fontSize: 13,
                        color: _passwordMessage!.startsWith('✓')
                            ? Colors.green.shade700
                            : Colors.red)),
              ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: _isSavingPassword
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.key, size: 18),
                label: const Text('Set Password'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1A5C2A),
                  side: const BorderSide(color: Color(0xFF1A5C2A)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _isSavingPassword ? null : _setPassword,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setPassword() async {
    final password = _newPasswordCtrl.text.trim();
    if (password.isEmpty) {
      setState(() => _passwordMessage = 'Please enter a password.');
      return;
    }
    if (password.length < 6) {
      setState(() => _passwordMessage = 'Password must be at least 6 characters.');
      return;
    }
    setState(() { _isSavingPassword = true; _passwordMessage = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      await api.setMemberCredentials(_member.memberId, password);
      setState(() {
        _isSavingPassword = false;
        _passwordMessage  = '✓ Password set successfully.';
        _newPasswordCtrl.clear();
      });
    } catch (e) {
      setState(() {
        _isSavingPassword = false;
        _passwordMessage  = 'Error: ${e.toString().replaceAll("Exception: ", "")}';
      });
    }
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
      initialValue: TextEditingValue(
          text: _selectedLocality?['commune'] ?? ''),
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) return _localities;
        return _localities.where((l) => (l['commune'] as String)
            .toLowerCase()
            .contains(textEditingValue.text.toLowerCase()));
      },
      displayStringForOption: (option) => option['commune'] as String,
      onSelected: _onLocalitySelected,
      fieldViewBuilder:
          (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Commune',
            prefixIcon: const Icon(Icons.location_on),
            suffixIcon: const Icon(Icons.arrow_drop_down),
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
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
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

  Widget _buildCertificateCard() {
    final cert = _member.certificate!;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFC8A96E), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified, color: Color(0xFFC8A96E)),
                const SizedBox(width: 8),
                const Text('Certificate',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
                icon: Icons.confirmation_number,
                label: 'Certificate ID',
                value: cert['certificate_id'] ?? ''),
            _InfoRow(
                icon: Icons.calendar_today,
                label: 'Issued Date',
                value: cert['issued_date'] ?? ''),

            if (_downloadError != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_downloadError!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),

            _isDownloading
                ? const Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(
                            color: Color(0xFFC8A96E)),
                        SizedBox(height: 8),
                        Text('Retrieving certificate...',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _downloadCertificate('pdf'),
                          icon: const Icon(Icons.picture_as_pdf,
                              color: Color(0xFFC8A96E)),
                          label: const Text('Download PDF',
                              style: TextStyle(
                                  color: Color(0xFFC8A96E))),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: Color(0xFFC8A96E)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _downloadCertificate('jpeg'),
                          icon: const Icon(Icons.image,
                              color: Color(0xFF1A5C2A)),
                          label: const Text('Download JPEG',
                              style: TextStyle(
                                  color: Color(0xFF1A5C2A))),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: Color(0xFF1A5C2A)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    if (_isEditing) {
      return Container(
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
                onPressed: _cancelEdit,
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
                onPressed: _isSaving ? null : _saveUpdate,
                icon: const Icon(Icons.save),
                label: const Text('Update', style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF1A5C2A),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
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
      child: ElevatedButton.icon(
        onPressed: _startEdit,
        icon: const Icon(Icons.edit),
        label: const Text('Edit', style: TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
        ),
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade400),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(
                  value.isNotEmpty ? value : '—',
                  style: TextStyle(
                    fontSize: 14,
                    color: value.isNotEmpty
                        ? Colors.black87
                        : Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool readOnly;
  final bool obscureText;

  const _EditField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.readOnly = false,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      readOnly: readOnly,
      obscureText: obscureText,
      style: readOnly ? TextStyle(color: Colors.grey.shade600) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        isDense: true,
        filled: readOnly,
        fillColor: readOnly ? Colors.grey.shade100 : null,
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  const _Banner(
      {required this.message,
      required this.isError,
      required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isError ? Colors.red.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isError ? Colors.red.shade200 : Colors.green.shade200),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: isError ? Colors.red : Colors.green,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style: TextStyle(
                      color: isError
                          ? Colors.red.shade700
                          : Colors.green.shade700,
                      fontSize: 13))),
          IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
        ],
      ),
    );
  }
}