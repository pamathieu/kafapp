class Member {
  final String memberId;
  final String companyId;
  String fullName;
  String dateOfBirth;
  String address;
  String phone;
  String email;
  String identificationNumber;
  String identificationType;
  String status;
  String? reason;
  String notes;
  String sex;
  Map<String, dynamic>? certificate;
  String? issuedDate;
  Map<String, dynamic>? locality; // {commune, code}
  String? setupToken;

  Member({
    required this.memberId,
    required this.companyId,
    required this.fullName,
    this.dateOfBirth = '',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.identificationNumber = '',
    this.identificationType = '',
    this.status = 'Active',
    this.reason,
    this.notes = '',
    this.sex = '',
    this.certificate,
    this.issuedDate,
    this.locality,
    this.setupToken,
  });

  factory Member.fromJson(Map<String, dynamic> json) {
    return Member(
      memberId: json['memberId'] ?? '',
      companyId: json['companyId'] ?? '',
      fullName: json['full_name'] ?? json['fullName'] ?? '',
      dateOfBirth: json['date_of_birth'] ?? json['dateOfBirth'] ?? '',
      address: json['address'] ?? '',
      phone: json['phone'] ?? '',
      email: json['email'] ?? '',
      identificationNumber: json['identification_number'] ?? '',
      identificationType: json['identification_type'] ?? '',
      status: _parseStatus(json['status']),
      reason: json['reason'] as String?,
      notes: json['notes'] ?? '',
      sex: json['sex'] ?? '',
      certificate: json['certificate'] as Map<String, dynamic>?,
      issuedDate: json['issued_date'] ?? json['issuedDate'],
      locality: json['locality'] as Map<String, dynamic>?,
      setupToken: json['setupToken'] as String?,
    );
  }

  static String _parseStatus(dynamic value) {
    if (value == null) return 'Active';
    if (value is String && (value == 'Active' || value == 'Pending' || value == 'Inactive')) return value;
    // Legacy bool support during migration
    if (value is bool) return value ? 'Active' : 'Inactive';
    if (value is String) return value.toLowerCase() == 'true' ? 'Active' : 'Inactive';
    return 'Active';
  }

  Map<String, dynamic> toJson() => {
        'memberId': memberId,
        'companyId': companyId,
        'full_name': fullName,
        'date_of_birth': dateOfBirth,
        'address': address,
        'phone': phone,
        'email': email,
        'identification_number': identificationNumber,
        'identification_type': identificationType,
        'status': status,
        'notes': notes,
        'sex': sex,
        if (locality != null) 'locality': locality,
      };

  Member copyWith({
    String? memberId,
    String? fullName,
    String? dateOfBirth,
    String? address,
    String? phone,
    String? email,
    String? identificationNumber,
    String? identificationType,
    String? status,
    String? reason,
    String? notes,
    String? sex,
    Map<String, dynamic>? locality,
  }) {
    return Member(
      memberId: memberId ?? this.memberId,
      companyId: companyId,
      fullName: fullName ?? this.fullName,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      identificationNumber: identificationNumber ?? this.identificationNumber,
      identificationType: identificationType ?? this.identificationType,
      status: status ?? this.status,
      reason: reason ?? this.reason,
      notes: notes ?? this.notes,
      sex: sex ?? this.sex,
      certificate: certificate,
      issuedDate: issuedDate,
      locality: locality ?? this.locality,
    );
  }

  /// Returns the commune name if locality is set
  String get communeName => locality?['commune'] ?? '';
  String get localityCode => locality?['code'] ?? '';
}