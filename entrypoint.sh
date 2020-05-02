#!/usr/bin/env bash

set -e

dummy_image_name=my_awesome_image
# split tags (to allow multiple comma-separated tags)
IFS=, read -ra INPUT_IMAGE_TAG <<< "$INPUT_IMAGE_TAG"

# helper functions
_has_value() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "INFO: Missing value $var_name" >&2
    return 1
  fi
}

_get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
    sort -n |
    tail -n 1
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_full_image_name() {
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${INPUT_IMAGE_NAME}
}

_tag() {
  local tag
  tag="${1:?You must provide a tag}"
  docker tag $dummy_image_name "$(_get_full_image_name):$tag"
}

_push() {
  local tag
  tag="${1:?You must provide a tag}"
  docker push "$(_get_full_image_name):$tag"
}

_push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  echo -e "\nPushing git tag: $git_tag"
  _tag $git_tag
  _push $git_tag
}

_push_image_tags() {
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    echo "Pushing: $tag"
    _push $tag
  done
  if [ "$INPUT_PUSH_GIT_TAG" = true ]; then
    _push_git_tag
  fi
}

_push_image_stages() {
  local stage_number=1
  local stage_image
  for stage in $(_get_stages); do
    echo -e "\nPushing stage: $stage_number"
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  echo -e "\nPushing stage: $stage_number"
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag $dummy_image_name $stage_image
  docker push $stage_image
}

__is_aws_ecr() {
  [[ $INPUT_REGISTRY =~ ^.+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]
  is_aws_ecr=$?
  aws_region=${BASH_REMATCH[1]}
  return $is_aws_ecr
}

__aws() {
  docker run --rm \
    --env AWS_ACCESS_KEY_ID=$INPUT_USERNAME \
    --env AWS_SECRET_ACCESS_KEY=$INPUT_PASSWORD \
    amazon/aws-cli:2.0.7 --region $aws_region "$@"
}

__login_to_aws_ecr() {
  __aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken' | base64 -d | cut -d: -f2 | docker login --username AWS --password-stdin $INPUT_REGISTRY
}

__create_aws_ecr_repos() {
  __aws ecr create-repository --repository-name "$INPUT_IMAGE_NAME" 2>&1 | grep -v RepositoryAlreadyExistsException
  __aws ecr create-repository --repository-name "$INPUT_IMAGE_NAME"-stages 2>&1 | grep -v RepositoryAlreadyExistsException
  return 0
}


# action steps
check_required_input() {
  echo -e "\n[Action Step] Checking required input..."
  _has_value IMAGE_NAME "${INPUT_IMAGE_NAME}" \
    && _has_value IMAGE_TAG "${INPUT_IMAGE_TAG}" \
    && return
  exit 1
}

login_to_registry() {
  echo -e "\n[Action Step] Log in to registry..."
  if _has_value USERNAME "${INPUT_USERNAME}" && _has_value PASSWORD "${INPUT_PASSWORD}"; then
    if __is_aws_ecr; then
      __login_to_aws_ecr && __create_aws_ecr_repos && return 0
    else
      echo "${INPUT_PASSWORD}" | docker login -u "${INPUT_USERNAME}" --password-stdin "${INPUT_REGISTRY}" \
        && return 0
    fi
    echo "Could not log in (please check credentials)" >&2
  else
    echo "No credentials provided" >&2
  fi

  not_logged_in=true
  echo "INFO: Won't be able to pull from private repos, nor to push to public/private repos" >&2
}

pull_cached_stages() {
  if [ "$INPUT_PULL_IMAGE_AND_STAGES" != true ]; then
    return
  fi
  echo -e "\n[Action Step] Pulling image..."
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  echo -e "\n[Action Step] Building image..."
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  if [ -n "${INPUT_BUILD_SSH_KEY:-}" ]; then
    echo $INPUT_BUILD_SSH_KEY > build_ssh_key
    chmod 600 build_ssh_key
    build_ssh_opt="--ssh ${INPUT_BUILD_SSH_KEY_NAME:-default}=./build_ssh_key"
  fi

  # build image using cache
  set -o pipefail
  set -x
  docker build \
    $cache_from \
    --tag $dummy_image_name \
    --file ${INPUT_CONTEXT}/${INPUT_DOCKERFILE} \
    ${INPUT_BUILD_EXTRA_ARGS} \
    ${build_ssh_opt} \
    ${INPUT_CONTEXT} | tee "$BUILD_LOG"
  set +x
}

tag_image() {
  echo -e "\n[Action Step] Tagging image..."
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    echo "Tagging: $tag"
    _tag $tag
  done
}

push_image_and_stages() {
  if [ "$INPUT_PUSH_IMAGE_AND_STAGES" != true ]; then
    return
  fi

  if [ "$not_logged_in" ]; then
    echo "ERROR: Can't push when not logged in to registry. Set push_image_and_stages=false if you don't want to push" >&2
    return 1
  fi

  echo -e "\n[Action Step] Pushing image..."
  _push_image_tags
  _push_image_stages
}

logout_from_registry() {
  if [ "$not_logged_in" ]; then
    return
  fi
  echo -e "\n[Action Step] Log out from registry..."
  docker logout "${INPUT_REGISTRY}"
}


# run the action
check_required_input
login_to_registry
pull_cached_stages
build_image
tag_image
push_image_and_stages
logout_from_registry
