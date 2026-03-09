import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/member.dart';

class MemberDetailScreen extends StatefulWidget {
  final Member member;
  const MemberDetailScreen({super.key, required this.member});

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  late Member _member;
  bool _isEditing = false;
  bool _isSaving = false;
  String? _successMessage;
  String? _errorMessage;

  // Edit controllers
  late TextEditingController _nameCtrl;
  late TextEditingController _dobCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _idNumberCtrl;
  late TextEditingController _idTypeCtrl;
  late TextEditingController _notesCtrl;
  late bool _editStatus;

  @override
  void initState() {
    super.initState();
    _member = widget.member;
    _initControllers();
  }

  void _initControllers() {
    _nameCtrl = TextEditingController(text: _member.fullName);
    _dobCtrl = TextEditingController(text: _member.dateOfBirth);
    _addressCtrl = TextEditingController(text: _member.address);
    _phoneCtrl = TextEditingController(text: _member.phone);
    _emailCtrl = TextEditingController(text: _member.email);
    _idNumberCtrl =
        TextEditingController(text: _member.identificationNumber);
    _idTypeCtrl =
        TextEditingController(text: _member.identificationType);
    _notesCtrl = TextEditingController(text: _member.notes);
    _editStatus = _member.status;
  }

  @override
  void dispose() {
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
      // Reset controllers to current member data
      _nameCtrl.text = _member.fullName;
      _dobCtrl.text = _member.dateOfBirth;
      _addressCtrl.text = _member.address;
      _phoneCtrl.text = _member.phone;
      _emailCtrl.text = _member.email;
      _idNumberCtrl.text = _member.identificationNumber;
      _idTypeCtrl.text = _member.identificationType;
      _notesCtrl.text = _member.notes;
      _editStatus = _member.status;
    });
  }

  Future<void> _saveUpdate() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final updatedMember = _member.copyWith(
        fullName: _nameCtrl.text.trim(),
        dateOfBirth: _dobCtrl.text.trim(),
        address: _addressCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        identificationNumber: _idNumberCtrl.text.trim(),
        identificationType: _idTypeCtrl.text.trim(),
        notes: _notesCtrl.text.trim(),
        status: _editStatus,
      );

      final api = context.read<AuthProvider>().apiService!;
      final result = await api.updateMember(updatedMember);

      setState(() {
        _member = result;
        _isEditing = false;
        _isSaving = false;
        _successMessage = 'Member updated successfully.';
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to update member: $e';
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
        content: Text(
            'Are you sure you want to $action ${_member.fullName}?'),
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
        _successMessage =
            'Member ${newStatus ? 'activated' : 'deactivated'} successfully.';
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to update status: $e';
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
                tooltip:
                    _member.status ? 'Deactivate Member' : 'Activate Member',
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
                    // Status messages
                    if (_successMessage != null)
                      _Banner(
                          message: _successMessage!,
                          isError: false,
                          onDismiss: () =>
                              setState(() => _successMessage = null)),
                    if (_errorMessage != null)
                      _Banner(
                          message: _errorMessage!,
                          isError: true,
                          onDismiss: () =>
                              setState(() => _errorMessage = null)),

                    // Header card
                    _buildHeaderCard(),
                    const SizedBox(height: 16),

                    // Member data
                    _isEditing
                        ? _buildEditForm()
                        : _buildReadOnlyInfo(),

                    const SizedBox(height: 16),

                    // Certificate info
                    if (_member.certificate != null)
                      _buildCertificateCard(),

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
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
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
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _member.fullName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _member.memberId,
                    style: const TextStyle(
                        color: Color(0xFFC8A96E), fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _member.status
                          ? Colors.green.withOpacity(0.2)
                          : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _member.status
                            ? Colors.green.shade400
                            : Colors.red.shade400,
                      ),
                    ),
                    child: Text(
                      _member.status ? '● Active' : '● Inactive',
                      style: TextStyle(
                        color: _member.status
                            ? Colors.green.shade400
                            : Colors.red.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyInfo() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'Personal Information'),
            _InfoRow(icon: Icons.person, label: 'Full Name', value: _member.fullName),
            _InfoRow(icon: Icons.cake, label: 'Date of Birth', value: _member.dateOfBirth),
            _InfoRow(icon: Icons.home, label: 'Address', value: _member.address),
            const Divider(height: 24),
            const _SectionHeader(title: 'Contact'),
            _InfoRow(icon: Icons.phone, label: 'Phone', value: _member.phone),
            _InfoRow(icon: Icons.email, label: 'Email', value: _member.email),
            const Divider(height: 24),
            const _SectionHeader(title: 'Identification'),
            _InfoRow(icon: Icons.badge, label: 'ID Number', value: _member.identificationNumber),
            _InfoRow(icon: Icons.credit_card, label: 'ID Type', value: _member.identificationType),
            if (_member.notes.isNotEmpty) ...[
              const Divider(height: 24),
              const _SectionHeader(title: 'Notes'),
              _InfoRow(icon: Icons.notes, label: 'Notes', value: _member.notes),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditForm() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'Personal Information'),
            _EditField(
                controller: _nameCtrl,
                label: 'Full Name',
                icon: Icons.person),
            const SizedBox(height: 12),
            _EditField(
                controller: _dobCtrl,
                label: 'Date of Birth',
                icon: Icons.cake,
                hint: 'YYYY-MM-DD'),
            const SizedBox(height: 12),
            _EditField(
                controller: _addressCtrl,
                label: 'Address',
                icon: Icons.home,
                maxLines: 2),
            const Divider(height: 24),
            const _SectionHeader(title: 'Contact'),
            _EditField(
                controller: _phoneCtrl,
                label: 'Phone',
                icon: Icons.phone,
                keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _EditField(
                controller: _emailCtrl,
                label: 'Email',
                icon: Icons.email,
                keyboardType: TextInputType.emailAddress),
            const Divider(height: 24),
            const _SectionHeader(title: 'Identification'),
            _EditField(
                controller: _idNumberCtrl,
                label: 'ID Number',
                icon: Icons.badge),
            const SizedBox(height: 12),
            _EditField(
                controller: _idTypeCtrl,
                label: 'ID Type',
                icon: Icons.credit_card),
            const Divider(height: 24),
            const _SectionHeader(title: 'Status'),
            SwitchListTile(
              value: _editStatus,
              onChanged: (val) => setState(() => _editStatus = val),
              title: Text(_editStatus ? 'Active' : 'Inactive'),
              subtitle: Text(
                  _editStatus ? 'Member is active' : 'Member is inactive'),
              activeColor: const Color(0xFFC8A96E),
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(height: 24),
            const _SectionHeader(title: 'Notes'),
            _EditField(
                controller: _notesCtrl,
                label: 'Notes',
                icon: Icons.notes,
                maxLines: 3),
          ],
        ),
      ),
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
                label: const Text('Update',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF1A1A2E),
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
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

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

  const _EditField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        isDense: true,
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
        color:
            isError ? Colors.red.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isError
                ? Colors.red.shade200
                : Colors.green.shade200),
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
