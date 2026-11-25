import '../core/phone_core.dart';
import '../models/phone_models.dart';

String formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String formatHistoryTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final clock = '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  final days = today.difference(day).inDays;
  if (days == 0) return clock;
  if (days == 1) return '昨天 $clock';
  if (days < 7) return '$days 天前 $clock';
  return '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')} $clock';
}

String outcomeLabel(CallOutcome outcome) => switch (outcome) {
      CallOutcome.completed => '已接通',
      CallOutcome.missed => '未接',
      CallOutcome.rejected => '对方拒接',
      CallOutcome.cancelled => '已取消',
      CallOutcome.failed => '呼叫失败',
    };

String outcomeLabelFor(CallOutcome outcome, CallDirection direction) {
  if (outcome == CallOutcome.rejected && direction == CallDirection.incoming) {
    return '已拒接';
  }
  return outcomeLabel(outcome);
}

String phaseLabel(CallPhase phase) => switch (phase) {
      CallPhase.dialing => '正在呼叫',
      CallPhase.ringing => '对方振铃',
      CallPhase.active => '通话中',
      CallPhase.incoming => '来电',
    };

String directionLabel(CallDirection direction) =>
    direction == CallDirection.incoming ? '来电' : '外呼';

final _reasonTokenRe = RegExp(
  r'SIP\s*;\s*cause\s*=\s*\d{3}\s*(?:;[^;]*)?;\s*text\s*=\s*"([A-Za-z0-9_]+)"',
  caseSensitive: false,
);
final _q850CauseRe = RegExp(
  r'Q\.850\s*;\s*cause\s*=\s*(\d+)',
  caseSensitive: false,
);
final _upstreamSipRe = RegExp(r'^UPSTREAM_SIP_(\d{3})$');

String? _extractReasonToken(List<String> sipReasons) {
  for (final header in sipReasons) {
    final m = _reasonTokenRe.firstMatch(header);
    if (m != null) return m.group(1)?.toUpperCase();
  }
  return null;
}

int? _extractQ850Cause(List<String> sipReasons) {
  for (final header in sipReasons) {
    final m = _q850CauseRe.firstMatch(header);
    if (m != null) return int.tryParse(m.group(1)!);
  }
  return null;
}

bool _isCompletedElsewhere(List<String> sipReasons) {
  for (final header in sipReasons) {
    if (header.toLowerCase().contains('call completed elsewhere')) {
      return true;
    }
  }
  return false;
}

bool _isMidCallFailureToken(String? token) {
  if (token == null) return false;
  if (_upstreamSipRe.hasMatch(token)) return true;
  return switch (token) {
    'ENGINE_MEDIA_FAILED' ||
    'ENGINE_MEDIA_TIMEOUT' ||
    'ENGINE_NO_AUDIO' ||
    'ENGINE_CALL_POLICY_ENDED' ||
    'ENGINE_EPOCH_CHANGED' ||
    'ENGINE_CALL_FAILED' ||
    'ENGINE_STATE_UNCERTAIN' ||
    'ENGINE_UNREACHABLE' ||
    'ENGINE_RESULT_UNKNOWN' ||
    'ENGINE_CALL_DISAPPEARED' ||
    'ENGINE_HANGUP_UNCONFIRMED' ||
    'UPSTREAM_CALL_FAILED' =>
      true,
    _ => false,
  };
}

String? formatRegistrationError(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (text.contains('缺少凭据')) return '缺少凭据，请重新导入';
  final codeMatch = RegExp(r'\b([45]\d{2}|6\d{2})\b').firstMatch(text);
  final code = codeMatch != null ? int.tryParse(codeMatch.group(1)!) : null;
  final lower = text.toLowerCase();
  if (code == 401 || code == 407 || lower.contains('unauthorized')) {
    return '账号认证失败（$code），请重新扫码配网';
  }
  if (code == 403 || lower.contains('forbidden')) {
    return '账号权限被拒绝（403）';
  }
  if (code == 404 || lower.contains('not found')) {
    return '未找到分机或域名（404）';
  }
  if (code == 408 || lower.contains('timeout') || lower.contains('timed out')) {
    return '注册响应超时，正在重试';
  }
  if (lower.contains('tls') ||
      lower.contains('ssl') ||
      lower.contains('cert') ||
      lower.contains('handshake')) {
    return 'TLS 证书校验或握手失败';
  }
  if (code == 502 || code == 503 || code == 504) {
    return '网关暂不可用（$code），正在重试';
  }
  if (lower.contains('resolve') || lower.contains('dns') || lower.contains('unreachable') || lower.contains('refused')) {
    return '无法连接 SIP 服务器，请检查网络';
  }
  if (code != null) {
    return '注册异常（SIP $code）';
  }
  return text;
}

({
  CallOutcome outcome,
  String? noticeTitle,
  String? noticeMessage,
  String? recordReason,
  bool isWarning,
}) describeCallEnd({required CoreCall finished, CallEndInfo? info}) {
  final reasons = info?.sipReasons ?? const [];
  final token = _extractReasonToken(reasons);
  final q850 = _extractQ850Cause(reasons);
  final code = info?.code;

  if (finished.answeredAt != null || finished.phase == CallPhase.active) {
    if (info?.localHangup != true) {
      String? msg;
      if (_isMidCallFailureToken(token)) {
        msg = switch (token) {
          'ENGINE_MEDIA_TIMEOUT' => '通话媒体超时中断，已自动结束。',
          'ENGINE_CALL_POLICY_ENDED' => '通话因线路策略限制或时长上限已结束。',
          'ENGINE_EPOCH_CHANGED' => '网关会话已重建，当前通话已中断。',
          'ENGINE_UNREACHABLE' ||
          'ENGINE_CALL_FAILED' ||
          'ENGINE_RESULT_UNKNOWN' ||
          'ENGINE_STATE_UNCERTAIN' ||
          'ENGINE_CALL_DISAPPEARED' ||
          'ENGINE_HANGUP_UNCONFIRMED' =>
            '线路状态异常，通话已中断，请确认线路状态。',
          _ => '语音媒体连接中断，通话已结束。',
        };
      } else {
        msg = switch (q850) {
          41 => '语音媒体连接中断，通话已结束。',
          102 => '通话媒体超时中断，已自动结束。',
          47 => '通话因线路策略限制或资源不可用已结束。',
          38 => '网关或线路连接异常，通话已中断。',
          _ => null,
        };
      }
      if (msg != null) {
        return (
          outcome: CallOutcome.failed,
          noticeTitle: '通话异常中断',
          noticeMessage: msg,
          recordReason: msg,
          isWarning: false,
        );
      }
    }
    return (
      outcome: CallOutcome.completed,
      noticeTitle: null,
      noticeMessage: null,
      recordReason: null,
      isWarning: false,
    );
  }

  if (finished.direction == CallDirection.incoming) {
    if (info?.localHangup == true) {
      return (
        outcome: CallOutcome.rejected,
        noticeTitle: null,
        noticeMessage: null,
        recordReason: null,
        isWarning: false,
      );
    }
    if (_isCompletedElsewhere(reasons)) {
      return (
        outcome: CallOutcome.cancelled,
        noticeTitle: null,
        noticeMessage: null,
        recordReason: '已在其他设备接听',
        isWarning: false,
      );
    }
    return (
      outcome: CallOutcome.missed,
      noticeTitle: null,
      noticeMessage: null,
      recordReason: null,
      isWarning: true,
    );
  }

  if (info?.localHangup == true) {
    return (
      outcome: CallOutcome.cancelled,
      noticeTitle: null,
      noticeMessage: null,
      recordReason: null,
      isWarning: false,
    );
  }

  switch (token) {
    case 'CARRIER_BUSY':
      return (
        outcome: CallOutcome.rejected,
        noticeTitle: '对方正忙',
        noticeMessage: '对方正在通话中或忙线，请稍后再拨。',
        recordReason: '对方正在通话中或忙线，请稍后再拨。',
        isWarning: true,
      );
    case 'CARRIER_CALL_REJECTED':
      return (
        outcome: CallOutcome.rejected,
        noticeTitle: '对方已拒接',
        noticeMessage: '对方拒绝接听本次通话。',
        recordReason: '对方拒绝接听本次通话。',
        isWarning: true,
      );
    case 'CARRIER_NO_ANSWER':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '无人接听',
        noticeMessage: '对方无人接听或暂时无法接通。',
        recordReason: '对方无人接听或暂时无法接通。',
        isWarning: true,
      );
    case 'CARRIER_CREDIT_LIMIT':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '余额不足',
        noticeMessage: '当前号码余额不足，无法拨打。',
        recordReason: '当前号码余额不足，无法拨打。',
        isWarning: false,
      );
    case 'CARRIER_SERVICE_DENIED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '服务受限',
        noticeMessage: '运营商拒绝提供本次通话服务。',
        recordReason: '运营商拒绝提供本次通话服务。',
        isWarning: false,
      );
    case 'CARRIER_USER_UNKNOWN':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '空号或号码无效',
        noticeMessage: '拨打的号码不存在，请核对后再试。',
        recordReason: '拨打的号码不存在，请核对后再试。',
        isWarning: false,
      );
    case 'CARRIER_AUTH_REJECTED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '呼出受限',
        noticeMessage: '当前线路被运营商限制呼出。',
        recordReason: '当前线路被运营商限制呼出。',
        isWarning: false,
      );
    case 'TEST_ROUTE_DISABLED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '测试短号未启用',
        noticeMessage: '该短号未开放（可用 9196 / 9197 / 9201–9209）。',
        recordReason: '该短号未开放（可用 9196 / 9197 / 9201–9209）。',
        isWarning: false,
      );
    case 'TEST_ENGINE_UNAVAILABLE':
    case 'TEST_ENGINE_ERROR':
      final testMsg = finished.peer == '9209'
          ? '请先在 /inter 控制台配置 Gemini API Key。'
          : '测试语音引擎暂不可用，请稍后再试。';
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '测试服务未就绪',
        noticeMessage: testMsg,
        recordReason: testMsg,
        isWarning: false,
      );
    case 'ENGINE_IMS_NOT_READY':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '线路未就绪',
        noticeMessage: '当前号码线路尚未完成 IMS 注册。',
        recordReason: '当前号码线路尚未完成 IMS 注册。',
        isWarning: false,
      );
    case 'ENGINE_LINE_BUSY':
    case 'CALL_IN_PROGRESS':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '线路占用中',
        noticeMessage: '当前号码线路正在通话中，请稍后再试。',
        recordReason: '当前号码线路正在通话中，请稍后再试。',
        isWarning: true,
      );
    case 'ENGINE_LINE_NOT_FOUND':
    case 'OUTBOUND_NOT_BOUND':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '未绑定外呼线路',
        noticeMessage: '当前账号未绑定可用的外呼线路。',
        recordReason: '当前账号未绑定可用的外呼线路。',
        isWarning: false,
      );
    case 'LINE_SUSPENDED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '线路已停用',
        noticeMessage: '当前号码线路已停用或暂停服务，请联系管理员。',
        recordReason: '当前号码线路已停用或暂停服务，请联系管理员。',
        isWarning: false,
      );
    case 'LINE_UNAVAILABLE':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '线路不可用',
        noticeMessage: '当前号码线路暂不可用，请稍后再试。',
        recordReason: '当前号码线路暂不可用，请稍后再试。',
        isWarning: false,
      );
    case 'ENGINE_MEDIA_FAILED':
    case 'ENGINE_MEDIA_TIMEOUT':
    case 'ENGINE_NO_AUDIO':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '媒体连接中断',
        noticeMessage: '语音媒体连接失败或中断，通话未能建立。',
        recordReason: '语音媒体连接失败或中断，通话未能建立。',
        isWarning: false,
      );
    case 'ENGINE_MEDIA_NOT_READY':
    case 'ENGINE_MEDIA_CONFLICT':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '线路媒体占用',
        noticeMessage: '线路媒体通道未就绪或已被占用，请稍后再试。',
        recordReason: '线路媒体通道未就绪或已被占用，请稍后再试。',
        isWarning: true,
      );
    case 'ENGINE_DIAL_TIMEOUT':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '呼叫响应超时',
        noticeMessage: '线路响应超时，不会自动重拨，请确认状态后再试。',
        recordReason: '线路响应超时，不会自动重拨，请确认状态后再试。',
        isWarning: false,
      );
    case 'ENGINE_EPOCH_CHANGED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '网关状态已变更',
        noticeMessage: '网关会话状态已更新，请重新发起呼叫。',
        recordReason: '网关会话状态已更新，请重新发起呼叫。',
        isWarning: true,
      );
    case 'ENGINE_CALL_POLICY_ENDED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '通话受策略限制',
        noticeMessage: '通话被网关线路策略终止。',
        recordReason: '通话被网关线路策略终止。',
        isWarning: false,
      );
    case 'ENGINE_RESULT_UNKNOWN':
    case 'ENGINE_STATE_UNCERTAIN':
    case 'ENGINE_CALL_DISAPPEARED':
    case 'ENGINE_HANGUP_UNCONFIRMED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '呼叫结果未知',
        noticeMessage: '网关未确认此次操作结果，不会自动重拨，请核对线路状态。',
        recordReason: '网关未确认此次操作结果，不会自动重拨，请核对线路状态。',
        isWarning: false,
      );
    case 'ENGINE_UNREACHABLE':
    case 'ENGINE_CALL_FAILED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '网关或线路异常',
        noticeMessage: '网关与卡池引擎通信异常，请稍后核对线路状态。',
        recordReason: '网关与卡池引擎通信异常，请稍后核对线路状态。',
        isWarning: false,
      );
    case 'ENGINE_BAD_REQUEST':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '呼叫参数无效',
        noticeMessage: '请求参数不被网关或线路接受，请核对号码格式。',
        recordReason: '请求参数不被网关或线路接受，请核对号码格式。',
        isWarning: false,
      );
    case 'UPSTREAM_SIP_487':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '呼叫被上游中止',
        noticeMessage: '上游网络终止了本次呼叫（SIP 487），未接通。',
        recordReason: '上游网络终止了本次呼叫（SIP 487），未接通。',
        isWarning: false,
      );
    case 'UPSTREAM_CALL_FAILED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '上游呼叫失败',
        noticeMessage: '上游运营商未能建立本次通话，请稍后再试。',
        recordReason: '上游运营商未能建立本次通话，请稍后再试。',
        isWarning: false,
      );
    case 'CODEC_MISMATCH':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '音频编码不兼容',
        noticeMessage: '双方没有可用的共同音频编码。',
        recordReason: '双方没有可用的共同音频编码。',
        isWarning: false,
      );
    case 'FORBIDDEN':
    case 'MISSING_GATEWAY_ACCOUNT':
    case 'ENGINE_UNAUTHORIZED':
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '无拨号权限',
        noticeMessage: '当前账号无权拨打该号码。',
        recordReason: '当前账号无权拨打该号码。',
        isWarning: false,
      );
  }

  if (token != null) {
    if (token.startsWith('ENGINE_REJECTED_')) {
      return (
        outcome: CallOutcome.failed,
        noticeTitle: '引擎拒绝呼叫',
        noticeMessage: '卡池引擎拒绝了此次呼叫（$token），请核对线路状态。',
        recordReason: '卡池引擎拒绝了此次呼叫（$token），请核对线路状态。',
        isWarning: false,
      );
    }
    final upstreamMatch = _upstreamSipRe.firstMatch(token);
    if (upstreamMatch != null) {
      final upstreamCode = int.tryParse(upstreamMatch.group(1)!);
      if (upstreamCode != null) {
        return _describeBySipCode(upstreamCode, peer: finished.peer, phase: finished.phase);
      }
    }
  }

  if (q850 != null && (code == null || code >= 500 || code == 480 || code == 404)) {
    switch (q850) {
      case 1:
        return (
          outcome: CallOutcome.failed,
          noticeTitle: '空号或号码无效',
          noticeMessage: '拨打的号码不存在（Q.850 #1），请核对后再试。',
          recordReason: '拨打的号码不存在（Q.850 #1），请核对后再试。',
          isWarning: false,
        );
      case 17:
        return (
          outcome: CallOutcome.rejected,
          noticeTitle: '对方正忙',
          noticeMessage: '对方正在通话中或忙线（Q.850 #17）。',
          recordReason: '对方正在通话中或忙线（Q.850 #17）。',
          isWarning: true,
        );
      case 19:
        return (
          outcome: CallOutcome.failed,
          noticeTitle: '无人接听',
          noticeMessage: '对方无人接听（Q.850 #19）。',
          recordReason: '对方无人接听（Q.850 #19）。',
          isWarning: true,
        );
      case 20:
        return (
          outcome: CallOutcome.failed,
          noticeTitle: '暂时无法接通',
          noticeMessage: '对方可能关机或不在服务区（Q.850 #20）。',
          recordReason: '对方可能关机或不在服务区（Q.850 #20）。',
          isWarning: true,
        );
      case 21:
        return (
          outcome: CallOutcome.rejected,
          noticeTitle: '对方已拒接',
          noticeMessage: '呼叫被对方或运营商拒绝（Q.850 #21）。',
          recordReason: '呼叫被对方或运营商拒绝（Q.850 #21）。',
          isWarning: true,
        );
    }
  }

  if (code != null) {
    return _describeBySipCode(code, peer: finished.peer, phase: finished.phase);
  }

  return (
    outcome: CallOutcome.cancelled,
    noticeTitle: null,
    noticeMessage: null,
    recordReason: null,
    isWarning: false,
  );
}

({
  CallOutcome outcome,
  String? noticeTitle,
  String? noticeMessage,
  String? recordReason,
  bool isWarning,
}) _describeBySipCode(
  int code, {
  required String peer,
  required CallPhase phase,
}) {
  return switch (code) {
    486 => (
        outcome: CallOutcome.rejected,
        noticeTitle: '对方正忙或已拒接',
        noticeMessage: '对方正在通话中或挂断了来电。',
        recordReason: '对方正在通话中或挂断了来电。',
        isWarning: true,
      ),
    603 => (
        outcome: CallOutcome.rejected,
        noticeTitle: '对方已拒接',
        noticeMessage: '呼叫被对方或线路拒绝。',
        recordReason: '呼叫被对方或线路拒绝。',
        isWarning: true,
      ),
    402 => (
        outcome: CallOutcome.failed,
        noticeTitle: '余额不足',
        noticeMessage: '当前号码余额不足，无法拨打。',
        recordReason: '当前号码余额不足，无法拨打。',
        isWarning: false,
      ),
    401 || 407 => (
        outcome: CallOutcome.failed,
        noticeTitle: '认证失败',
        noticeMessage: 'SIP 账号凭据失效，请重新扫码配网。',
        recordReason: 'SIP 账号凭据失效，请重新扫码配网。',
        isWarning: false,
      ),
    403 => RegExp(r'^\d{2,5}$').hasMatch(peer)
        ? (
            outcome: CallOutcome.failed,
            noticeTitle: '短号未启用',
            noticeMessage: '该测试短号未开放（可用 9196 / 9197 / 9201–9209）。',
            recordReason: '该测试短号未开放（可用 9196 / 9197 / 9201–9209）。',
            isWarning: false,
          )
        : (
            outcome: CallOutcome.failed,
            noticeTitle: '呼叫被拒绝',
            noticeMessage: '当前账号或拨号规则不允许拨打该号码。',
            recordReason: '当前账号或拨号规则不允许拨打该号码。',
            isWarning: false,
          ),
    404 => (
        outcome: CallOutcome.failed,
        noticeTitle: '号码不存在',
        noticeMessage: '拨打的号码为空号或未找到目标。',
        recordReason: '拨打的号码为空号或未找到目标。',
        isWarning: false,
      ),
    408 => phase == CallPhase.ringing
        ? (
            outcome: CallOutcome.failed,
            noticeTitle: '对方无人接听',
            noticeMessage: '振铃超时，对方未接听电话。',
            recordReason: '振铃超时，对方未接听电话。',
            isWarning: true,
          )
        : (
            outcome: CallOutcome.failed,
            noticeTitle: '呼叫超时',
            noticeMessage: '网络或服务器响应超时，请稍后再试。',
            recordReason: '网络或服务器响应超时，请稍后再试。',
            isWarning: false,
          ),
    480 => (
        outcome: CallOutcome.failed,
        noticeTitle: '暂时无法接通',
        noticeMessage: '对方可能关机、不在服务区或暂时无法接听。',
        recordReason: '对方可能关机、不在服务区或暂时无法接听。',
        isWarning: true,
      ),
    484 => (
        outcome: CallOutcome.failed,
        noticeTitle: '号码不完整',
        noticeMessage: '输入的号码位数不完整，请核对后再拨。',
        recordReason: '输入的号码位数不完整，请核对后再拨。',
        isWarning: false,
      ),
    487 => (
        outcome: CallOutcome.failed,
        noticeTitle: '呼叫被远端中止',
        noticeMessage: '远端或上游网络中止了本次呼叫（SIP 487）。',
        recordReason: '远端或上游网络中止了本次呼叫（SIP 487）。',
        isWarning: false,
      ),
    488 => (
        outcome: CallOutcome.failed,
        noticeTitle: '编码不兼容',
        noticeMessage: '双方音频编码不匹配，无法建立通话。',
        recordReason: '双方音频编码不匹配，无法建立通话。',
        isWarning: false,
      ),
    502 || 503 || 504 => peer == '9209'
        ? (
            outcome: CallOutcome.failed,
            noticeTitle: 'AI 语音未就绪',
            noticeMessage: '请先在 /inter 控制台检查 Gemini API Key 配置。',
            recordReason: '请先在 /inter 控制台检查 Gemini API Key 配置。',
            isWarning: false,
          )
        : (
            outcome: CallOutcome.failed,
            noticeTitle: '服务暂不可用',
            noticeMessage: '当前线路忙或网关暂时不可用，请稍后再试。',
            recordReason: '当前线路忙或网关暂时不可用，请稍后再试。',
            isWarning: false,
          ),
    _ => code >= 400
        ? (
            outcome: CallOutcome.failed,
            noticeTitle: '未能接通',
            noticeMessage: '呼叫未成功（状态码 $code），不会自动重拨。',
            recordReason: '呼叫未成功（状态码 $code），不会自动重拨。',
            isWarning: false,
          )
        : (
            outcome: CallOutcome.cancelled,
            noticeTitle: null,
            noticeMessage: null,
            recordReason: null,
            isWarning: false,
          ),
  };
}
