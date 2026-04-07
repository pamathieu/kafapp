import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../models/member.dart';

class ApiService {
  static const String _baseUrl   = 'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';
  static const String _region    = 'us-east-1';
  static const String _service   = 'execute-api';
  static const String _companyId = 'KAFA-001';

  final String  _accessKeyId;
  final String  _secretAccessKey;
  final String? _sessionToken;

  ApiService({
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
  })  : _accessKeyId     = accessKeyId,
        _secretAccessKey = secretAccessKey,
        _sessionToken    = sessionToken;

  // ── SigV4 helpers ────────────────────────────────────────────────────────────

  List<int> _hmacSha256Bytes(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _sha256Hex(String data) =>
      sha256.convert(utf8.encode(data)).toString();

  String _pad(int v, int w) => v.toString().padLeft(w, '0');

  Map<String, String> _signRequest({
    required String method,
    required Uri    uri,
    required String body,
  }) {
    final now        = DateTime.now().toUtc();
    final datestamp  = _pad(now.year, 4) + _pad(now.month, 2) + _pad(now.day, 2);
    final amzdate    = '${datestamp}T${_pad(now.hour, 2)}${_pad(now.minute, 2)}${_pad(now.second, 2)}Z';
    final bodyHash   = _sha256Hex(body);
    final host       = uri.host;

    final signingHeaders = <String, String>{
      'host':                 host,
      'x-amz-date':           amzdate,
      'x-amz-content-sha256': bodyHash,
      if (_sessionToken != null) 'x-amz-security-token': _sessionToken!,
      if (body.isNotEmpty) 'content-type': 'application/json',
    };

    final sortedKeys       = signingHeaders.keys.toList()..sort();
    final canonicalHeaders = sortedKeys.map((k) => '$k:${signingHeaders[k]}\n').join();
    final signedHeaders    = sortedKeys.join(';');

    final sortedParams = uri.queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final queryString = sortedParams
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final canonicalRequest = [
      method,
      uri.path,
      queryString,
      canonicalHeaders,
      signedHeaders,
      bodyHash,
    ].join('\n');

    final credentialScope = '$datestamp/$_region/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzdate,
      credentialScope,
      _sha256Hex(canonicalRequest),
    ].join('\n');

    final signingKey = [datestamp, _region, _service, 'aws4_request'].fold(
      utf8.encode('AWS4$_secretAccessKey') as List<int>,
      (prev, part) => _hmacSha256Bytes(prev, part),
    );

    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();

    final authHeader =
        'AWS4-HMAC-SHA256 Credential=$_accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    return {
      'Authorization':         authHeader,
      'x-amz-date':            amzdate,
      'x-amz-content-sha256':  bodyHash,
      if (_sessionToken != null) 'x-amz-security-token': _sessionToken!,
      if (body.isNotEmpty) 'content-type': 'application/json',
    };
  }

  // ── API calls ────────────────────────────────────────────────────────────────

  /// GET /retrieve?phone= — returns {pdf: url, jpeg: url} (no auth)
  Future<Map<String, String>> getCertificateLinks(String phone) async {
    final uri = Uri.parse(
        '$_baseUrl/retrieve?phone=${Uri.encodeComponent(phone)}');
    final response = await http.get(uri);
    if (response.statusCode == 200) {
      final body = json.decode(response.body);
      final docs = body['documents'] ?? {};
      return {
        'pdf':  (docs['pdf']  ?? {})['download_url'] ?? '',
        'jpeg': (docs['jpeg'] ?? {})['download_url'] ?? '',
      };
    }
    throw Exception(
        'Failed to retrieve certificate links: ${response.statusCode} ${response.body}');
  }

  /// POST /members/set-payment-access — admin grants/revokes payment access (SigV4)
  Future<void> setPaymentAccess(String memberId, bool enabled) async {
    final uri  = Uri.parse('$_baseUrl/members/set-payment-access');
    final body = json.encode({
      'memberId':  memberId,
      'companyId': _companyId,
      'enabled':   enabled,
    });
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) return;
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to update payment access');
  }

  /// POST /member/payment — record a premium payment (no SigV4, public)
  Future<String> makePayment({
    required String policyNo,
    required String memberId,
    required double amount,
    required String paymentMethod,
    String schedSK           = '',
    String externalRef       = '',
    String paymentPeriod     = '',
    Map<String, String> externalDetails = const {},
  }) async {
    final uri  = Uri.parse('$_baseUrl/member/payment');
    final body = json.encode({
      'policyNo':        policyNo,
      'memberId':        memberId,
      'companyId':       _companyId,
      'amount':          amount,
      'paymentMethod':   paymentMethod,
      'schedSK':         schedSK,
      'externalRef':     externalRef,
      'paymentPeriod':   paymentPeriod,
      'externalDetails': externalDetails,
    });
    final response = await http.post(uri,
        headers: {'Content-Type': 'application/json'}, body: body);
    final data = json.decode(response.body);
    if (response.statusCode == 201) return data['referenceNo'] as String;
    throw Exception(data['error'] ?? 'Payment failed');
  }

  /// POST /member/acknowledge-payment — member dismisses notification (no SigV4)
  Future<void> acknowledgePayment(String memberId) async {
    final uri  = Uri.parse('$_baseUrl/member/acknowledge-payment');
    final body = json.encode({'memberId': memberId, 'companyId': _companyId});
    await http.post(uri,
        headers: {'Content-Type': 'application/json'}, body: body);
  }

  /// GET /member/policy — fetch policies for a member (no SigV4)
  Future<List<Map<String, dynamic>>> getMemberPolicies(String memberId) async {
    final uri      = Uri.parse('$_baseUrl/member/policy?memberId=${Uri.encodeComponent(memberId)}');
    final response = await http.get(uri, headers: {'Content-Type': 'application/json'});
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['policies'] ?? []);
    }
    throw Exception('Failed to load policies: ${response.statusCode}');
  }

  /// POST /member/claim — submit a new claim (no SigV4)
  Future<String> createClaim({
    required String policyNo,
    required String memberId,
    required String claimType,
    required String description,
  }) async {
    final uri  = Uri.parse('$_baseUrl/member/claim');
    final body = json.encode({
      'policyNo':    policyNo,
      'memberId':    memberId,
      'claimType':   claimType,
      'description': description,
    });
    final response = await http.post(uri,
        headers: {'Content-Type': 'application/json'}, body: body);
    final data = json.decode(response.body);
    if (response.statusCode == 201) return data['claimNo'] as String;
    throw Exception(data['error'] ?? 'Claim submission failed');
  }

  /// POST /member/login — member self-service (no SigV4, public endpoint)
  Future<Map<String, dynamic>> memberLogin(String identifier, String password) async {
    final uri      = Uri.parse('$_baseUrl/member/login');
    final body     = json.encode({'identifier': identifier, 'password': password});
    final response = await http.post(uri,
        headers: {'Content-Type': 'application/json'}, body: body);
    final data = json.decode(response.body);
    if (response.statusCode == 200) return data;
    throw Exception(data['error'] ?? 'Login failed');
  }

  /// POST /members/set-credentials — admin sets a member password (SigV4)
  Future<void> setMemberCredentials(String memberId, String password) async {
    final uri  = Uri.parse('$_baseUrl/members/set-credentials');
    final body = json.encode({
      'memberId':  memberId,
      'companyId': _companyId,
      'password':  password,
    });
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) return;
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to set credentials');
  }

  /// GET /companies — returns current sequence counter from kopera-company
  Future<int> getCompanySequence() async {
    final uri     = Uri.parse('$_baseUrl/companies?companyId=$_companyId');
    final headers = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['sequence'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// GET /localities — list all communes
  Future<List<Map<String, dynamic>>> listLocalities() async {
    final uri      = Uri.parse('$_baseUrl/localities');
    final headers  = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['localities'] ?? []);
    }
    throw Exception('Failed to load localities: ${response.statusCode}');
  }

  Future<List<Member>> listMembers() async {
    final uri      = Uri.parse('$_baseUrl/members/list?companyId=$_companyId');
    final headers  = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List membersJson = data['members'] ?? [];
      return membersJson.map((m) => Member.fromJson(m)).toList();
    }
    throw Exception('Failed to load members: ${response.statusCode} ${response.body}');
  }

  Future<Member> getMember(String memberId) async {
    final uri      = Uri.parse('$_baseUrl/members?memberId=$memberId&companyId=$_companyId');
    final headers  = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return Member.fromJson(json.decode(response.body));
    }
    throw Exception('Member not found');
  }

  Future<Member> editMember(String memberId) async {
    final uri      = Uri.parse('$_baseUrl/members/edit');
    final body     = json.encode({'memberId': memberId, 'companyId': _companyId});
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return Member.fromJson(data['member'] ?? data);
    }
    throw Exception('Failed to load member for editing');
  }

  /// Update member — supports renaming memberId via oldMemberId field
  Future<Member> updateMember(Member member, {String? oldMemberId}) async {
    final uri  = Uri.parse('$_baseUrl/members/update');
    final body = json.encode({
      'memberId':              member.memberId,
      'oldMemberId':           oldMemberId ?? member.memberId,
      'companyId':             _companyId,
      'full_name':             member.fullName,
      'date_of_birth':         member.dateOfBirth,
      'address':               member.address,
      'phone':                 member.phone,
      'email':                 member.email,
      'identification_number': member.identificationNumber,
      'identification_type':   member.identificationType,
      'status':                member.status,
      'notes':                 member.notes,
      if (member.locality != null) 'locality': member.locality,
    });
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return Member.fromJson(data['member'] ?? data);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to update member: ${response.statusCode}');
  }

  /// Create a new member
  Future<Member> createMember(Member member) async {
    final uri  = Uri.parse('$_baseUrl/members/create');
    final body = json.encode({
      'memberId':              member.memberId,
      'companyId':             _companyId,
      'full_name':             member.fullName,
      'date_of_birth':         member.dateOfBirth,
      'address':               member.address,
      'phone':                 member.phone,
      'email':                 member.email,
      'identification_number': member.identificationNumber,
      'identification_type':   member.identificationType,
      'status':                member.status,
      'notes':                 member.notes,
      if (member.locality != null) 'locality': member.locality,
    });
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 201) {
      final data = json.decode(response.body);
      return Member.fromJson(data['member'] ?? data);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to create member: ${response.statusCode}');
  }
}