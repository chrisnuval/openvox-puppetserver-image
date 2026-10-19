# Dependency-free subset of Checkov's Kubernetes checks, for environments without checkov.
# Runs with the Ruby inside the image itself:
#
#   podman run --rm -v ./k8s:/k8s:ro,Z -v ./scripts:/scripts:ro,Z --entrypoint ruby \
#     openvox-server-ubi:8.17.0 /scripts/k8s-policy-check.rb /k8s/openvox-server.yaml
#
# Check IDs and meanings match Checkov's, so results map 1:1 onto Checkov / Prisma reports.
# Exits 1 if any check fails.
require "yaml"

WORKLOADS = %w[Pod Deployment StatefulSet DaemonSet ReplicaSet Job CronJob].freeze

def pod_spec(doc)
  case doc["kind"]
  when "Pod" then doc["spec"]
  when "CronJob" then doc.dig("spec", "jobTemplate", "spec", "template", "spec")
  else doc.dig("spec", "template", "spec")
  end
end

# Effective value: container securityContext first, then the pod's
def sc(pod, container, key)
  c = (container["securityContext"] || {})[key]
  c.nil? ? (pod["securityContext"] || {})[key] : c
end

CHECKS = {
  "CKV_K8S_8"  => ["Liveness Probe Should be Configured",          ->(p, c) { c["livenessProbe"] }],
  "CKV_K8S_9"  => ["Readiness Probe Should be Configured",         ->(p, c) { c["readinessProbe"] }],
  "CKV_K8S_10" => ["CPU requests should be set",                   ->(p, c) { c.dig("resources", "requests", "cpu") }],
  "CKV_K8S_11" => ["CPU limits should be set",                     ->(p, c) { c.dig("resources", "limits", "cpu") }],
  "CKV_K8S_12" => ["Memory requests should be set",                ->(p, c) { c.dig("resources", "requests", "memory") }],
  "CKV_K8S_13" => ["Memory limits should be set",                  ->(p, c) { c.dig("resources", "limits", "memory") }],
  "CKV_K8S_14" => ["Image Tag should be fixed - not latest or blank", ->(p, c) { c["image"].to_s =~ /@sha256:|:(?!latest$)[^\/:]+$/ }],
  "CKV_K8S_15" => ["Image Pull Policy should be Always",           ->(p, c) { c["imagePullPolicy"] == "Always" }],
  "CKV_K8S_16" => ["Container should not be privileged",           ->(p, c) { sc(p, c, "privileged") != true }],
  "CKV_K8S_20" => ["Containers should not run with allowPrivilegeEscalation", ->(p, c) { sc(p, c, "allowPrivilegeEscalation") == false }],
  "CKV_K8S_22" => ["Use read-only filesystem for containers where possible", ->(p, c) { sc(p, c, "readOnlyRootFilesystem") == true }],
  "CKV_K8S_23" => ["Minimize the admission of root containers",    ->(p, c) { sc(p, c, "runAsNonRoot") == true || sc(p, c, "runAsUser").to_i > 0 }],
  "CKV_K8S_28" => ["Minimize the admission of containers with the NET_RAW capability",
                   ->(p, c) { Array(c.dig("securityContext", "capabilities", "drop")).any? { |x| %w[ALL NET_RAW].include?(x) } }],
  "CKV_K8S_29" => ["Apply security context to your pods and containers", ->(p, c) { p["securityContext"] }],
  "CKV_K8S_30" => ["Apply security context to your containers",    ->(p, c) { c["securityContext"] }],
  "CKV_K8S_31" => ["Ensure that the seccomp profile is set to docker/default or runtime/default",
                   ->(p, c) { %w[RuntimeDefault Localhost].include?(sc(p, c, "seccompProfile")&.dig("type")) }],
  "CKV_K8S_37" => ["Minimize the admission of containers with capabilities assigned",
                   ->(p, c) { Array(c.dig("securityContext", "capabilities", "drop")).include?("ALL") }],
  "CKV_K8S_38" => ["Ensure that Service Account Tokens are only mounted where necessary",
                   ->(p, c) { p["automountServiceAccountToken"] == false }],
  "CKV_K8S_40" => ["Containers should run as a high UID to avoid host conflict", ->(p, c) { sc(p, c, "runAsUser").to_i >= 10000 }],
  "CKV_K8S_43" => ["Image should use digest",                      ->(p, c) { c["image"].to_s.include?("@sha256:") }],
}.freeze

failed = passed = 0
docs = ARGV.flat_map { |file| YAML.load_stream(File.read(file)).compact }
# CKV2_K8S_6: some NetworkPolicy in the namespace must select the workload's pod labels
netpols = docs.select { |d| d["kind"] == "NetworkPolicy" }
selected = lambda do |doc|
  labels = doc.dig("spec", "template", "metadata", "labels") || doc.dig("metadata", "labels") || {}
  netpols.any? do |np|
    np.dig("metadata", "namespace") == doc.dig("metadata", "namespace") &&
      (np.dig("spec", "podSelector", "matchLabels") || {}).all? { |k, v| labels[k] == v }
  end
end
docs.each do |doc|
    next unless WORKLOADS.include?(doc["kind"])
    pod = pod_spec(doc) or next
    name = "#{doc['kind']}.#{doc.dig('metadata', 'namespace') || 'default'}.#{doc.dig('metadata', 'name')}"
    ns_ok = !%w[default].include?(doc.dig("metadata", "namespace").to_s) && doc.dig("metadata", "namespace")
    puts "#{ns_ok ? 'PASS' : 'FAIL'}  CKV_K8S_21  The default namespace should not be used  [#{name}]"
    ns_ok ? passed += 1 : failed += 1
    np_ok = selected.call(doc)
    puts "#{np_ok ? 'PASS' : 'FAIL'}  CKV2_K8S_6  Minimize the admission of pods which lack an associated NetworkPolicy  [#{name}]"
    np_ok ? passed += 1 : failed += 1
    (pod["containers"] + Array(pod["initContainers"])).each do |c|
      CHECKS.each do |id, (title, test)|
        ok = test.call(pod, c)
        puts "#{ok ? 'PASS' : 'FAIL'}  #{id.ljust(10)}  #{title}  [#{name}/#{c['name']}]"
        ok ? passed += 1 : failed += 1
      end
    end
end
puts "\nPassed checks: #{passed}, Failed checks: #{failed}"
exit(failed.zero? ? 0 : 1)
